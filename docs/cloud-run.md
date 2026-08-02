# Cloud Run 構成・セットアップ手順

perldoc.jp を Google Cloud Run で動かすための構成と、初期セットアップの手順。

## 構成の概要

```
[perldoc-jp/translation] --push--> repository_dispatch ─┐
[perldoc-jp/perldoc.jp]  --push--------------------------┤
[schedule: 日次保険]  ───────────────────────────────────┤
                                                         v
                GitHub Actions (.github/workflows/deploy.yml)
                  translation取得 → SQLite構築 → データ生成
                  → テスト → Docker build → Artifact Registry push
                  → Cloud Run deploy
                                                         v
[ユーザー] → Cloudflare (Worker) → Cloud Run (asia-northeast1)
                           - min-instances=0 (無アクセス時のコストほぼゼロ)
                           - イメージに read-only SQLite + translation docs を焼き込み
                           - 実行時の書き込みは /tmp (tmpfs) のみ
                             (Xslate キャッシュと diff 用の一時ファイル)
```

- データ更新は「イメージ再ビルド + 再デプロイ」に一本化されている。VPS 時代の
  cron (10分毎の script/update.pl) に相当する処理は Dockerfile の databuild
  ステージが担う。
- 翻訳の diff (`/docs/*/diff`) はキャッシュせず都度計算する。GNU diff の
  外部コマンド化 (`PJP::HTMLDiff`) により perlfunc.pod 級の最悪ケースでも
  数秒以内に収まる。クエリ付き GET のため Cloudflare にはキャッシュされず
  毎回 Cloud Run に届くので、連続アクセス対策として Cloudflare の
  レートリミットルールを設定しておくことを推奨する。
  ただし `--allow-unauthenticated` のため `<service>.run.app` の URL 自体は
  公開のままであり、Cloudflare を経由しない直アクセスにはレートリミットは
  効かない。直アクセス側の実質的な上限装置は max-instances (=3) で、
  コスト暴走はしない前提の設計になっている (完全に塞ぐには LB + ingress
  制限が必要で、本構成のコスト方針とは釣り合わない)。
- 同じ理由で、**アプリは `X-Forwarded-*` を誰からでも信用する状態にある**。
  app.psgi は `Plack::Middleware::ReverseProxy` を無条件で有効にしているため、
  run.app へ直接 `X-Forwarded-Host: evil.example` を送れば Location をその
  ホストに向けられる。Worker 側でクライアント由来の `X-Forwarded-*` を
  一掃しているので perldoc.jp 経由では起こらないが、run.app 経由の経路は
  残る。攻撃者が汚染できるのは自分のリクエストへの応答だけ (ブラウザは
  ナビゲーションでこれらのヘッダを送れない) で、run.app のホスト名には
  phishing 価値も無いため現状は許容している。塞ぐなら Worker が付ける
  共有ヘッダを条件に `enable_if` でミドルウェアを限定する。

## 初期セットアップ (一度だけ)

gcloud のデフォルトプロジェクト設定には依存せず、すべてのコマンドで `--project` を
明示する。以下のシェル変数を定義してから順に実行すること。

```sh
PROJECT_ID=perldoc-jp-XXXXXX  # 作成するプロジェクト ID
REGION=asia-northeast1
```

### 1. プロジェクトと API

```sh
gcloud projects create "$PROJECT_ID"

# 請求先アカウントの紐付け。これが無いと services enable が失敗する
gcloud billing projects link "$PROJECT_ID" \
  --billing-account=XXXXXX-XXXXXX-XXXXXX

gcloud services enable --project="$PROJECT_ID" \
  run.googleapis.com artifactregistry.googleapis.com \
  iam.googleapis.com iamcredentials.googleapis.com sts.googleapis.com
```

`compute.googleapis.com` は有効化しない。Cloud Run のランタイムには専用のサービス
アカウントを作る (§3) ため、Compute Engine のデフォルト SA を使わない。

### 2. Artifact Registry

```sh
gcloud artifacts repositories create perldoc-jp \
  --project="$PROJECT_ID" \
  --repository-format=docker \
  --location="$REGION"

# 古いイメージの自動削除 (最新15世代 + buildcache タグを保持)。
# schedule ビルドにより変更が無い日も日次でイメージが積まれるため、
# keepCount が小さいと平穏な期間だけで実質同一イメージに埋まり
# ロールバックに使える世代が残らなくなることに注意
cat > /tmp/cleanup-policy.json <<'EOF'
[
  {
    "name": "keep-buildcache",
    "action": {"type": "Keep"},
    "condition": {"tagPrefixes": ["buildcache"], "tagState": "TAGGED"}
  },
  {
    "name": "keep-recent",
    "action": {"type": "Keep"},
    "mostRecentVersions": {"keepCount": 15}
  },
  {
    "name": "delete-old",
    "action": {"type": "Delete"},
    "condition": {"olderThan": "30d", "tagState": "ANY"}
  }
]
EOF
gcloud artifacts repositories set-cleanup-policies perldoc-jp \
  --project="$PROJECT_ID" \
  --location="$REGION" \
  --policy=/tmp/cleanup-policy.json \
  --no-dry-run
```

### 3. ランタイムサービスアカウント

Cloud Run のインスタンスが名乗るサービスアカウント。アプリは Google Cloud の API を
一切呼ばないため、ロールは付与しない。

```sh
gcloud iam service-accounts create perldoc-jp-run \
  --project="$PROJECT_ID" \
  --display-name='perldoc.jp Cloud Run runtime'

RUNTIME_SA=perldoc-jp-run@${PROJECT_ID}.iam.gserviceaccount.com
```

デフォルトの Compute Engine SA (`<PROJECT_NUMBER>-compute@developer.gserviceaccount.com`)
はプロジェクトレベルの `roles/editor` を持つため使わない。

Artifact Registry からイメージを pull するのは Cloud Run のサービスエージェント
(`service-<PROJECT_NUMBER>@serverless-robot-prod.iam.gserviceaccount.com`) で、これは
API 有効化時に自動で作られプロジェクトレベルの `roles/run.serviceAgent` を持つ。
権限を絞る作業でこのバインドを消すとデプロイがイメージを取得できなくなる。

### 4. Cloud Run サービスの作成

サービス単位で IAM を付与する (§5) には、リソースとしてのサービスが先に存在している
必要がある。Artifact Registry にはまだイメージが無いので、Google が公開している
プレースホルダイメージで作る。

```sh
gcloud run deploy perldoc-jp \
  --project="$PROJECT_ID" \
  --image us-docker.pkg.dev/cloudrun/container/hello \
  --region "$REGION" \
  --service-account "$RUNTIME_SA" \
  --execution-environment gen2 \
  --memory 1Gi --cpu 1 \
  --min-instances 0 --max-instances 3 \
  --concurrency 4 \
  --cpu-boost \
  --timeout 60 \
  --port 8080 \
  --allow-unauthenticated
```

- `--concurrency 4` は Starlet のワーカー数 (`STARLET_MAX_WORKERS`、既定 4) に
  合わせている。変える場合は両方を揃えること。デフォルトの 80 のままだと
  4 ワーカーに大量のリクエストが詰まりタイムアウトの原因になる。
- deploy.yml も `--image` 以外は同じフラグ一式を毎回指定しているため、この初回コマンドと
  デプロイの実行順序に関わらずサービス設定は self-correcting になる。
  設定を変えるときは deploy.yml 側も合わせて更新すること。

### 5. デプロイ用サービスアカウントと Workload Identity Federation

GitHub Actions からキーレスで認証するための設定。権限はプロジェクトではなく、操作対象の
リソース (Cloud Run サービス / Artifact Registry リポジトリ / サービスアカウント) に
付与する。

```sh
gcloud iam service-accounts create perldoc-jp-deployer \
  --project="$PROJECT_ID" \
  --display-name='perldoc.jp GitHub Actions deployer'

PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')
SA=perldoc-jp-deployer@${PROJECT_ID}.iam.gserviceaccount.com

# リビジョンの作成・トラフィック切替・IAM ポリシー設定 (--allow-unauthenticated)
gcloud run services add-iam-policy-binding perldoc-jp \
  --project="$PROJECT_ID" --region="$REGION" \
  --member="serviceAccount:$SA" --role=roles/run.admin

# イメージの push と buildcache の読み書き
gcloud artifacts repositories add-iam-policy-binding perldoc-jp \
  --project="$PROJECT_ID" --location="$REGION" \
  --member="serviceAccount:$SA" --role=roles/artifactregistry.writer

# ランタイム SA を名乗らせてデプロイする権限
gcloud iam service-accounts add-iam-policy-binding "$RUNTIME_SA" \
  --project="$PROJECT_ID" \
  --member="serviceAccount:$SA" --role=roles/iam.serviceAccountUser

gcloud iam workload-identity-pools create github \
  --project="$PROJECT_ID" \
  --location=global

# ref 条件により master 以外のブランチからは認証できない
# (workflow_dispatch で誤って別ブランチを選んでも未レビューのコードは
# デプロイされない)
gcloud iam workload-identity-pools providers create-oidc perldoc-jp \
  --project="$PROJECT_ID" \
  --location=global \
  --workload-identity-pool=github \
  --issuer-uri="https://token.actions.githubusercontent.com" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository" \
  --attribute-condition="assertion.repository == 'perldoc-jp/perldoc.jp' && assertion.ref == 'refs/heads/master'"

gcloud iam service-accounts add-iam-policy-binding "$SA" \
  --project="$PROJECT_ID" \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/github/attribute.repository/perldoc-jp/perldoc.jp" \
  --role=roles/iam.workloadIdentityUser
```

### 6. GitHub リポジトリの Variables と Secrets

perldoc-jp/perldoc.jp の Settings → Secrets and variables → Actions → Variables に:

| 変数 | 値 |
|---|---|
| `GCP_PROJECT_ID` | プロジェクト ID |
| `GCP_WORKLOAD_IDENTITY_PROVIDER` | `projects/<PROJECT_NUMBER>/locations/global/workloadIdentityPools/github/providers/perldoc-jp` |
| `GCP_SERVICE_ACCOUNT` | `perldoc-jp-deployer@<PROJECT_ID>.iam.gserviceaccount.com` |
| `CLOUDFLARE_ACCOUNT_ID` | Cloudflare のアカウント ID |
| `CLOUD_RUN_URL` | Cloud Run のサービス URL (§9 の Worker のオリジン) |

Secrets に:

| シークレット | 値 |
|---|---|
| `CLOUDFLARE_API_TOKEN` | 権限に **Edit Cloudflare Workers** を持つ API トークン |

WIF の attribute-condition が `refs/heads/master` に固定されているため、master へ
merge するまで GitHub Actions からはデプロイできない。cutover までは §7 の手順で
手元からビルドとデプロイを行う。

### 7. 手動でのビルドとデプロイ

master へ merge する前の cutover はこの手順で行う。使うのは操作者自身の gcloud
認証情報で、デプロイ用 SA (§5) は経由しない。

事前に `data/years.pl` が過去年 (2013〜) を含む現物になっていることを確認する。
`.dockerignore` に含まれないため作業ツリーの内容がそのままイメージに焼き込まれ、
databuild はそこへ前年+当年を累積マージする (「運用」の最後の項目を参照)。

```sh
PROJECT_ID=perldoc-jp-XXXXXX
REGION=asia-northeast1
RUNTIME_SA=perldoc-jp-run@${PROJECT_ID}.iam.gserviceaccount.com
IMAGE=${REGION}-docker.pkg.dev/${PROJECT_ID}/perldoc-jp/app
TAG=manual-$(date +%Y%m%d%H%M%S)

# 一度だけ: docker が Artifact Registry へ push できるようにする
gcloud auth configure-docker "${REGION}-docker.pkg.dev"

# translation の HEAD に固定する (deploy.yml と同じ)
TRANSLATION_COMMIT=$(git ls-remote https://github.com/perldoc-jp/translation.git refs/heads/master | cut -f1)
test -n "$TRANSLATION_COMMIT"

# Cloud Run は linux/amd64 のみ対応。Apple Silicon ではエミュレーションで動くため、
# 初回は CPAN 依存の XS ビルドを含めて時間がかかる
docker buildx build \
  --platform linux/amd64 \
  --target runtime \
  --build-arg "TRANSLATION_COMMIT=$TRANSLATION_COMMIT" \
  --cache-from "type=registry,ref=$IMAGE:buildcache" \
  --tag "$IMAGE:$TAG" \
  --push \
  .
```

- `$IMAGE:buildcache` がまだ push されていない場合は警告が出るだけで、通常の
  フルビルドになる。
- push したイメージを Cloud Run が受け付けない場合は `--provenance=false` を足す
  (buildx が既定で付ける attestation により manifest が image index になるため)。

本番同等の FS 制約で起動確認してからデプロイする (deploy.yml の smoke test と同じ):

```sh
docker run -d --name smoke --read-only --tmpfs /tmp \
  -e PORT=8080 -p 8080:8080 "$IMAGE:$TAG"
for _ in $(seq 1 30); do
  curl -fsS -o /dev/null http://127.0.0.1:8080/ && break
  sleep 2
done
curl -fsS http://127.0.0.1:8080/ | grep 'perldoc.jp' > /dev/null
curl -fsS -o /dev/null http://127.0.0.1:8080/docs/perl/perl.pod
curl -fsS http://127.0.0.1:8080/translators | grep '年</h2>' > /dev/null
curl -fsS http://127.0.0.1:8080/static/docs.json | grep 'Acme::Bleach' > /dev/null
curl -fsS -o /dev/null http://127.0.0.1:8080/favicon.ico
docker rm -f smoke
```

デプロイする。フラグは §4 および deploy.yml と同一で、`--image` だけが変わる:

```sh
gcloud run deploy perldoc-jp \
  --project="$PROJECT_ID" \
  --image "$IMAGE:$TAG" \
  --region "$REGION" \
  --service-account "$RUNTIME_SA" \
  --execution-environment gen2 \
  --memory 1Gi --cpu 1 \
  --min-instances 0 --max-instances 3 \
  --concurrency 4 \
  --cpu-boost \
  --timeout 60 \
  --port 8080 \
  --allow-unauthenticated
```

デプロイ後の確認:

```sh
URL=$(gcloud run services describe perldoc-jp \
  --project="$PROJECT_ID" --region="$REGION" --format='value(status.url)')

curl -fsS "$URL/" | grep 'perldoc.jp' > /dev/null
curl -fsS -o /dev/null "$URL/docs/perl/perl.pod"
curl -fsS "$URL/translators" | grep '年</h2>' > /dev/null
curl -fsS "$URL/static/docs.json" | grep 'Acme::Bleach' > /dev/null
curl -fsS -o /dev/null "$URL/favicon.ico"
# runtime の allowlist COPY の列挙漏れ検出 (toc.txt / toc-var.txt)
curl -fsS -o /dev/null "$URL/index/core"
curl -fsS -o /dev/null "$URL/index/variable"
# perlfunc に組み込み関数リンクが焼き込まれているか (databuild 中の
# functions.txt の有無に依存し、prove では捕まらない)。空の @REGEXP で
# 生成されるとリテラル置換分の 9 件程度しか残らない
curl -fsS "$URL/docs/perl/5.36.0/perlfunc.pod" | grep -o 'href="/func/[a-z]*"' | sort -u | wc -l

# ランタイム SA はロールを持たないので、アプリケーションログが
# Cloud Logging に届いていることをここで確かめておく
gcloud logging read \
  'resource.type="cloud_run_revision" AND resource.labels.service_name="perldoc-jp"' \
  --project="$PROJECT_ID" --limit=20 --freshness=10m

# --allow-unauthenticated はサービスの IAM ポリシーを書き換える。allUsers の
# run.invoker と、デプロイ用 SA の run.admin (§5) が両方残っていることを確認する
gcloud run services get-iam-policy perldoc-jp \
  --project="$PROJECT_ID" --region="$REGION"
```

`$URL` が空になる場合は `gcloud run deploy` が最後に表示する `Service URL:` を使う。

master へ merge すると以降は Deploy workflow が自動で回り、この手順は不要になる。

### 8. translation リポジトリ側の workflow

perldoc-jp/translation に以下を追加すると、翻訳の push で即座に再ビルドされる
(なくても日次の schedule で反映される):

```yaml
# .github/workflows/notify-perldoc-jp.yml
name: Notify perldoc.jp

on:
  push:
    branches:
      - master

jobs:
  notify:
    runs-on: ubuntu-latest
    steps:
      - run: gh api repos/perldoc-jp/perldoc.jp/dispatches \
               -f event_type=translation-updated
        env:
          GH_TOKEN: ${{ secrets.PERLDOC_JP_DISPATCH_TOKEN }}
```

`PERLDOC_JP_DISPATCH_TOKEN` は perldoc-jp/perldoc.jp への Contents:
Read and write 権限を持つ fine-grained PAT (または GitHub App トークン)。

### 9. Cloudflare (Worker で Cloud Run にリバースプロキシする)

perldoc.jp へのリクエストは Cloudflare の Worker が受け、`<service>.run.app` へ
リバースプロキシする。Cloud Run のドメインマッピングは使わない。

- オリジンが `<service>.run.app` なので、TLS 証明書は Google が管理する run.app の
  ものがそのまま使える。証明書の発行・更新が運用対象にならない。Cloud Run の
  ドメインマッピングは自前証明書を持ち込めず、Google 管理証明書の更新時に
  Cloudflare のような前段プロキシが検証リクエストを傍受して更新が失敗しうる
- perldoc.jp 側の証明書は Cloudflare の Universal SSL が担う (`*.perldoc.jp` を含む)
- Cloud Run 側のドメイン所有権確認 (`gcloud domains verify`) は不要

Worker 以外の設定は Cloudflare のダッシュボードで行う。Rules 系 (Redirect Rules /
Cache Rules) の条件は、ビルダーを使わず **Edit expression** に式を直接貼ること。
ビルダーの `And` / `Or` ボタンは「その演算子で条件を 1 行追加する」ボタンであり、
既存の条件間の演算子を切り替えるものではない (押すと空の条件行が増えるだけ)。
式を貼ったあとは Expression Preview が意図どおりか必ず読むこと。

#### Worker

実装は `worker/src/index.js`、設定は `worker/wrangler.toml`。master への push で
`worker/` が変わったときだけ `.github/workflows/deploy-worker.yml` がデプロイする。

- `X-Forwarded-Host` の付与は必須。`Amon2::Web::redirect` は `Plack::Request->base`
  (= `HTTP_HOST` 由来) で `Location` の絶対 URL を組むため、これが無いと `/func/*`
  などの正規化リダイレクトが `Location: https://<service>.run.app/...` を返す。
  app.psgi の `Plack::Middleware::ReverseProxy` がこのヘッダを `HTTP_HOST` に戻す
- オリジンの URL は wrangler.toml に置かず、デプロイ時に `--var` で注入する。
  値は GitHub Variables の `CLOUD_RUN_URL` (§6)

`CLOUD_RUN_URL` に入れる値:

```sh
gcloud run services describe perldoc-jp \
  --project="$PROJECT_ID" --region="$REGION" --format='value(status.url)'
```

手元からデプロイする場合 (cutover 時など)。wrangler は `worker/package.json` の
exact な devDependency で、`worker/package-lock.json` が依存グラフ全体を固定する。
バージョンを変えるときは lockfile も一緒に更新すること。

**インストールはトークンを渡さない状態で行う** (`npm ci` を実行してから
`CLOUDFLARE_API_TOKEN` を export する)。依存の install フックはインストール時の
環境変数を読めるため、トークンを置いたまま入れると依存の乗っ取りがそのまま
トークンの奪取になる:

```sh
cd worker
npm ci
export CLOUDFLARE_ACCOUNT_ID=... CLOUDFLARE_API_TOKEN=...
npm exec --offline --no -- wrangler deploy --var "ORIGIN:$(gcloud run services describe perldoc-jp \
  --project="$PROJECT_ID" --region="$REGION" --format='value(status.url)')"
```

#### DNS

- `perldoc.jp` (apex) は Worker の **Custom Domain** として登録する。DNS レコードと
  証明書は Cloudflare が自動で作る。Workers の route にプレースホルダの
  `AAAA 100::` を置く方式は Cloudflare が非推奨としている。apex は wrangler.toml の
  routes には書かずダッシュボードで登録する。`wrangler deploy` が DNS の切り替えを
  伴うと事故になるため (staging は壊れても影響がないので `[env.staging]` の routes で
  宣言的に作っている)
- `www.perldoc.jp` と `new.perldoc.jp` は **proxied (オレンジ雲)** にする。
  リクエストは下の Redirect Rule がエッジで終端するのでオリジンには届かず、
  レコードの値 (A / CNAME いずれでも) は使われない。グレー雲だと Cloudflare の
  エッジを通らないため Redirect Rule が発火せず、証明書も無いので HTTPS で
  そもそも接続できない。なお値が無視されるのは Redirect Rule が有効な間だけなので、
  ルールを外すときは向き先が生きているか確かめること

#### Redirect Rules (www / new → apex)

- 「If incoming requests match」で **Custom filter expression** を選ぶ
  (既定は Wildcard pattern)
- 式: `http.host in {"www.perldoc.jp" "new.perldoc.jp"}`
- 「Then」の **Type を Dynamic に変える** (既定は Static)。Static はリダイレクト先を
  固定 URL でしか書けずパスを引き継げない。Dynamic にすると URL 欄が Expression 欄に
  変わる
- Expression: `concat("https://perldoc.jp", http.request.uri)`
- Status code: 301
- 「Preserve query string」は**オフ**。`http.request.uri` がクエリを含むため、
  オンにすると二重に付く (`http.request.uri.path` はクエリを含まない)

Worker の Custom Domain は apex だけなので、www/new は Worker を起動せず
Redirect Rules だけで処理される。

#### Cache Rules

`/static/*` は Cloud Run 上のアプリ (`Plack::Middleware::Static`) が配信する。
TTL は app.psgi が付ける `Cache-Control` を唯一の情報源とする
(`/static/docs.json` と `/static/rss/` は 2 時間、それ以外の `/static/*` と
`/favicon.ico` は 4 時間)。

`css` / `js` / `png` / `ico` は Cloudflare の既定キャッシュ対象拡張子なので、
`Cache-Control` がそのまま効きルールは要らない。一方 `.json` と `.rss` は対象外で、
ルールが無いと `/static/docs.json` と `/static/rss/recent.rss` は
`cf-cache-status: DYNAMIC` のまま毎回オリジンに届く。この 2 つをキャッシュ対象に
するルールを 1 本だけ置く:

- 式: `http.request.uri.path eq "/static/docs.json" or starts_with(http.request.uri.path, "/static/rss/")`
- Cache eligibility: **Eligible for cache**
- Edge TTL: **Use cache-control header if present** (オリジンの 2 時間が使われる)

**Cache eligibility と Edge TTL は両方を設定する。** どちらかが欠けていても
`cf-cache-status` は `DYNAMIC` のままで、式がマッチしていない場合と区別が付かない。
`DYNAMIC` が続くときに疑う順は (1) 式がマッチしていない (2) Cache eligibility が
未設定 (3) Edge TTL が未設定。式は Expression Preview で確認できるので (1) から潰す。

Edge TTL に `Use cache-control header if present` を選べるのは、app.psgi が
`Cache-Control` を返すからこそ。オリジンがまだ返していない状態
(Cache-Control を入れる前のイメージが動いている間) にこのモードにすると TTL が
決まらないので、その間は `Ignore cache-control header and use this TTL` に
2 時間 (Free プランで指定できる最小値) を入れておく。

`/static/*` 全体を対象にするルールは置かない。既定でキャッシュされる拡張子まで
ルールに含めると、TTL をオリジンの `Cache-Control` とルールの両方に持つことになる。

エッジ TTL をオリジンより長くしないのは、`cf.cacheKey` が Enterprise 限定で
キャッシュキーが run.app の URL になり、perldoc.jp のゾーンからの URL 単位パージが
効かないため。ファイル名にダイジェストも入らないので、長い TTL は
配信物を差し替えられないまま抱えることになる。

Worker の `fetch()` による subrequest にも Cache Rules は適用される (優先順位は
Worker の `cf` 設定 > Cache Rules > Page Rules)。式をパスだけで書いておけばオリジンの
ホスト名は影響しない。ルールを入れたら `cf-cache-status` が `DYNAMIC` から
`MISS` → `HIT` に変わることを必ず確認する。

関連するゾーン設定 (Caching → Configuration):

- `Browser Cache TTL`: **Respect Existing Headers**。固定値だと app.psgi の
  `Cache-Control` を上書きする (既定は 4 時間)
- `Caching Level`: Standard
- `Development Mode`: OFF (ON の間はキャッシュされない)
- Page Rules は使わない (Cache Rules と設定が重なる)

HTML は Cloudflare の既定でキャッシュされず、app.psgi も `Cache-Control` を付けない。

#### SSL/TLS

- `Always Use HTTPS`: **有効**。HTTP で来たリクエストをエッジで HTTPS へ 301 する
- `Minimum TLS Version`: **1.2**
- perldoc.jp 側の証明書は Universal SSL (`*.perldoc.jp` と apex) が担う
- **SSL/TLS の暗号化モード (Flexible / Full / Full strict) は本構成では効かない**。
  Worker の `fetch()` は Worker ランタイムからオリジンへの独立した HTTPS リクエストで、
  ゾーンの暗号化モードに従わない。run.app の証明書は Google が管理するため
  検証も常に成立する。逆に cutover 前にモードを上げると、:443 を待受していない
  旧オリジンへの接続が壊れるので触らないこと
- 暗号化モードの `Automatic mode` (Cloudflare が定期スキャンでモードを決める) が
  有効だと、スキャンのたびにモードが変わり得る。上記のとおり本構成では効かない
  設定なので実害は無いが、意図しない変更が混ざるのを避けたいなら手動に固定する
- `HSTS` は未設定。有効にすると HTTP でのアクセス手段を長期間放棄することになるため、
  `Always Use HTTPS` が安定してから別途判断する

#### 動作確認 (staging.perldoc.jp)

本番の apex に触らないまま構成をまるごと検証する。`staging.perldoc.jp` を Worker の
Custom Domain にすれば、Cache Rules の式がパスベースなのでそのまま適用され、cutover
後の挙動を事前に確かめられる。`workers.dev` のサブドメインだけではゾーンの Cache
Rules も Redirect Rules も適用されないためキャッシュの確認には足りない。

1. Cloud Run にデプロイし (§7)、URL を取っておく:
   ```sh
   ORIGIN=$(gcloud run services describe perldoc-jp \
     --project="$PROJECT_ID" --region="$REGION" --format='value(status.url)')
   ```
2. staging の Worker をデプロイする。`wrangler.toml` の `[env.staging]` が
   `staging.perldoc.jp` を Custom Domain として作る。`NOINDEX` を渡すと Worker が
   `X-Robots-Tag: noindex, nofollow` を足すので、本番と重複した内容が検索結果に
   出るのを防げる:
   ```sh
   cd worker
   npm ci   # トークンを export する前に入れる (§9 の手元デプロイ参照)
   export CLOUDFLARE_ACCOUNT_ID=... CLOUDFLARE_API_TOKEN=...
   npm exec --offline --no -- wrangler deploy --env staging --var "ORIGIN:$ORIGIN" --var NOINDEX:1
   ```
3. Cache Rules を入れる。パスだけで書いてあるので staging にも本番にも同じに効く
4. 確認する:
   ```sh
   BASE=https://staging.perldoc.jp

   # アプリの主要な経路 (deploy.yml の smoke test と同じ観点)
   curl -fsS "$BASE/" | grep 'perldoc.jp' > /dev/null
   curl -fsS -o /dev/null "$BASE/docs/perl/perl.pod"
   curl -fsS "$BASE/translators" | grep '年</h2>' > /dev/null
   curl -fsS "$BASE/static/docs.json" | grep 'Acme::Bleach' > /dev/null
   curl -fsS -o /dev/null "$BASE/favicon.ico"

   # 都度計算する diff。perlfunc.pod のような大きい pod でも試しておく
   curl -fsS -o /dev/null -w '%{time_total}\n' \
     "$BASE/docs/perl/5.38.0/perl.pod/diff?target=perl%2F5.36.0%2Fperl.pod"

   # X-Forwarded-Host が効いていること。/chomp は /func/chomp へのリダイレクトなので、
   # ここに run.app が出たら Worker 側の不備 (/func/chomp 自体は 200 なので使えない)
   curl -sS -o /dev/null -D - "$BASE/chomp" | grep -i '^location:'

   # オリジンの Cache-Control (docs.json は 2 時間、css は 4 時間)
   curl -sS -o /dev/null -D - "$BASE/static/docs.json"     | grep -i '^cache-control:'
   curl -sS -o /dev/null -D - "$BASE/static/css/style.css" | grep -i '^cache-control:'

   # 2 回叩いて cf-cache-status が MISS → HIT になること (docs.json は要 Cache Rules)
   curl -sS -o /dev/null -D - "$BASE/static/docs.json" | grep -i '^cf-cache-status:'
   curl -sS -o /dev/null -D - "$BASE/static/docs.json" | grep -i '^cf-cache-status:'
   curl -sS -o /dev/null -D - "$BASE/static/css/style.css" | grep -i '^cf-cache-status:'
   curl -sS -o /dev/null -D - "$BASE/static/css/style.css" | grep -i '^cf-cache-status:'

   # HTML はキャッシュしない (DYNAMIC のままであること)
   curl -sS -o /dev/null -D - "$BASE/" | grep -i '^cf-cache-status:'

   # staging がクロール除けになっていること
   curl -sS -o /dev/null -D - "$BASE/" | grep -i '^x-robots-tag:'
   ```

   症状から切り分ける:
   - `/chomp` の `Location` に run.app が出る → Worker が `X-Forwarded-Host` を
     付けていない
   - `/static/docs.json` が `DYNAMIC` のまま → Cache Rules 側 (式 / Cache eligibility /
     Edge TTL のいずれか)
   - `/favicon.ico` が 404、`Cache-Control` が付かない → デプロイされているイメージが
     古い (Worker や Cloudflare の設定ではない)
5. cutover 後に片付ける (残すと Workers の枠を無駄に使う)。Custom Domain が
   Cloudflare 側に残っていたら合わせて外す:
   ```sh
   npm exec --offline --no -- wrangler delete --env staging
   ```

www/new の Redirect Rule は本番のホスト名にしか書けないため、この段階では確認できない。
cutover 時に確かめる。

#### 切り替え手順

1. Cloud Run にデプロイし、`status.url` を確認する
2. 「動作確認」のとおり staging で構成を検証する。Cache Rules・SSL/TLS・Browser Cache
   TTL はゾーン単位の設定なので、ここで入れたものが cutover 後の本番にもそのまま効く
3. 本番の Worker をデプロイする (`--env` なし):
   ```sh
   cd worker
   npm exec --offline --no -- wrangler deploy --var "ORIGIN:$ORIGIN"
   ```
4. apex の既存レコードを Worker の Custom Domain に**置き換える**。Custom Domain の
   登録は既存の apex レコードと共存できないので、ここが切り替えの瞬間になる
5. Redirect Rule を入れてから、www/new を **proxied (オレンジ雲)** に切り替える。
   グレー雲のままではリクエストが Cloudflare のエッジを通らず Redirect Rule が
   発火しない。順序を逆にすると一時的にリクエストが旧オリジンへ流れる
6. 確認: apex が 200、`/chomp` の `Location` が perldoc.jp を指すこと、
   `www.perldoc.jp` が 301 でクエリを保持すること、`/static/docs.json` の
   `cf-cache-status`。「動作確認」の curl を `BASE=https://perldoc.jp` で回すのが早い
7. Cache Rules を最終形にする。この時点でオリジンが `Cache-Control` を返しているので、
   短期ルールの Edge TTL を `Ignore cache-control header and use this TTL` から
   **`Use cache-control header if present`** に切り替える。`/static/*` 全体を対象に
   するルールが残っていれば削除する (TTL の情報源を app.psgi 側 1 箇所に寄せる)
8. staging の Worker を消す

ロールバックは Custom Domain を外して元の apex レコードに戻す。

#### run.app への直アクセス

`--allow-unauthenticated` のため `<service>.run.app` は公開のままで、Worker を
経由しないアクセスにはキャッシュもレートリミットも効かない (「構成の概要」のとおり
実質的な上限装置は max-instances)。

`X-Forwarded-Host` を信頼する構成なので、直アクセスでは `Location` のホストを
任意の値にできる。Cloudflare のキャッシュには入らない経路なのでキャッシュ汚染には
繋がらず、攻撃者が自分自身をリダイレクトさせられるだけ。塞ぐなら Worker が共有
シークレットのヘッダを付け、アプリ側で一致しないリクエストを 403 にするのが最も安い。

#### Workers の枠と、Worker を挟まない構成

Workers Free は 10 万リクエスト/日で、**Cloudflare のキャッシュにヒットした
リクエストも 1 件として数える**。超える場合は Workers Paid (月 $5, 1000 万
リクエスト込み、超過 100 万あたり $0.30)。

Worker を挟まない構成にする場合の選択肢:

- Origin Rules の Host header override で run.app を直接オリジンにする。DNS だけでは
  `Host: perldoc.jp` が run.app に届いて 404 になるため書き換えが必須で、この機能は
  **Enterprise 限定** (SNI override も同様)
- Cloud Run を Global External Application Load Balancer の背後に置く。自前証明書
  (Cloudflare Origin CA) が使えて Google が推奨する構成でもあるが、転送ルールだけで
  概算 月 $18〜25 かかり、min-instances=0 のコスト方針とは釣り合わない

## 旧 VPS の cron ジョブとの対応

VPS で `PLACK_ENV=deployment` の crontab が回していたジョブと、移行後の担当:

| 旧 cron ジョブ | 旧頻度 | 移行後 |
|---|---|---|
| `update_deployment.sh` (= `script/update.pl`) | 1日4回 (3〜6時台) | Dockerfile の databuild ステージ。translation への push で即時、加えて日次 schedule |
| `script/create_recent.pl` | 毎時 | 同上 (databuild) |
| `script/create_year_data.pl $(date +%Y)` | 毎日 4:05 | 同上 (databuild)。ターゲットは前年に変更し、前年+当年を毎ビルド git から再導出する (年またぎの欠落を自己修復) |
| `script/create_docs.json.sh` | 6時間毎 | 同上。`script/create_docs_json.pl` に置き換え |
| `script/generate_heavy_diff.pl` | 毎時 | **廃止**。diff 計算を GNU diff 外部コマンド化 (`PJP::HTMLDiff`) で高速化したため、都度計算で足りる |
| `script/scrape_cpan.pl` | (コメントアウト済み) | 廃止 |

反映頻度は旧構成 (1日4回) より速くなる。translation の push を
repository_dispatch で受けるため、翻訳がマージされてから数分で反映される。

### `static/docs.json` は外部から参照されている

旧 crontab のコメントにある通り、`static/docs.json` は Chrome 拡張と
Firefox アドオンが参照している。移行後もパスと JSON 構造 (`{パッケージ名: パス}`)
を変えないこと。

- <https://chrome.google.com/webstore/detail/iedgkpbokcjamkpoglfbefmdmclkljhc>
- <https://addons.mozilla.org/ja/firefox/addon/perldocjp-firefox-addon/>

デプロイ後に古い docs.json が残る時間は app.psgi が付ける `Cache-Control` で決まる
(2 時間。旧構成の更新間隔は 6 時間毎だった)。エッジもこれを尊重する (§9)。

## 運用

- **翻訳の反映**: translation への push → 自動デプロイ (数分)。手動で回す場合は
  Actions の Deploy workflow を workflow_dispatch で実行
- **schedule の自動無効化に注意**: public リポジトリの scheduled workflow は、
  リポジトリに 60 日間アクティビティが無いと GitHub により自動で無効化される。
  perldoc.jp 本体はコミット頻度が低く、translation の更新 (repository_dispatch)
  はこの判定のアクティビティにならないため、「日次保険」だけが黙って止まる
  ことがある (commit-years-data ジョブの自動コミットはアクティビティになるため、
  translation の更新が続いている限りは起きにくい)。Actions タブの Deploy workflow に無効化の告知が出ていたら
  re-enable すること (repository_dispatch / workflow_dispatch 起動は無効化の
  対象外なので、translation 起点の反映は止まらない)
- **ロールバック**: `gcloud run services update-traffic perldoc-jp \
  --project <PROJECT_ID> --region asia-northeast1 --to-revisions <REVISION>=100`
- **ログ**: Cloud Console の Cloud Run → perldoc-jp → ログ。
  リクエストログは Cloud Run が自動で記録する。アプリケーションログ
  (Log::Minimal) は app.psgi のミドルウェアが STDERR に出したものが
  Cloud Logging に入る (リクエスト毎のアクセスログをアプリは出さない)
- **data/years.pl の自動更新 (年次作業は不要)**: databuild は `create_year_data.pl <前年>`
  で前年+当年を毎ビルド translation の git 履歴から再導出し、デプロイ成功後に
  `commit-years-data` ジョブが再導出結果を master へ自動コミットする
  (変更がある場合のみ。実装は `.github/workflows/commit-years-data.yml`)。再導出されるのは前年+当年だけなので、この書き戻しが
  無いと、ある年の統計は 2 年後にシードのコミット時点の内容で凍結されてしまう。
  自動コミットが止まっていた場合も、対象年の翌年中に一度
  `perl script/create_year_data.pl <対象年>` の結果をコミットすれば回復する。
  継続的な書き戻しは、翻訳ファイルの削除で再導出できなくなるエントリを
  削除前に確定させる保険も兼ねる
- **`data/years.pl` の完全性 (cutover の必須前提)**: `create_year_data.pl` は
  既存の `data/years.pl` に当年分を累積マージする方式なので、空の状態から
  ビルドすると当年分の翻訳者統計しか含まれない。過去年 (2013〜) を含む
  現物を **VPS から回収して git 管理下にコミットしてから** 本番切替すること。
  ローカルビルドで `/translators` が 200 を返しても、それはページが
  描画されたことを示すだけで年次データの完全性は保証しない。
