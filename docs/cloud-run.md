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
[ユーザー] → Cloudflare → Cloud Run (asia-northeast1)
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

### 6. GitHub リポジトリの Variables

perldoc-jp/perldoc.jp の Settings → Secrets and variables → Actions → Variables に:

| 変数 | 値 |
|---|---|
| `GCP_PROJECT_ID` | プロジェクト ID |
| `GCP_WORKLOAD_IDENTITY_PROVIDER` | `projects/<PROJECT_NUMBER>/locations/global/workloadIdentityPools/github/providers/perldoc-jp` |
| `GCP_SERVICE_ACCOUNT` | `perldoc-jp-deployer@<PROJECT_ID>.iam.gserviceaccount.com` |

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
# 初回は carton install の XS ビルドを含めて時間がかかる
docker buildx build \
  --platform linux/amd64 \
  --target runtime \
  --build-arg "TRANSLATION_COMMIT=$TRANSLATION_COMMIT" \
  --tag "$IMAGE:$TAG" \
  --push \
  .
```

- Artifact Registry に buildcache が積まれた後は
  `--cache-from type=registry,ref=$IMAGE:buildcache` を足すと databuild の再実行を避けられる。
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

### 9. カスタムドメイン (Cloudflare は既存のものを流用)

> **注意**: Cloud Run のドメインマッピングはプレビュー段階の機能で、
> Google はレイテンシの問題を理由に本番用途には推奨していない
> (asia-northeast1 が対応リージョンであることは確認済み)。
> 本構成は Cloudflare が前面に立つため影響は限定的と見込むが、
> レイテンシや証明書で問題が出る場合は末尾の Worker 代替に切り替えること。

1. ドメインの所有権を確認する (ブラウザで Search Console が開く)。これが済んでいないと
   次のドメインマッピング作成が失敗する:
   ```sh
   gcloud domains verify perldoc.jp
   ```
2. ドメインマッピングを作成:
   ```sh
   gcloud beta run domain-mappings create \
     --project="$PROJECT_ID" \
     --service perldoc-jp --domain perldoc.jp --region "$REGION"
   ```
3. Cloudflare の perldoc.jp のレコードを一時的に DNS only (グレー雲) にして、
   案内された `ghs.googlehosted.com` への CNAME に変更する
4. Google 管理証明書の発行完了を待つ (`gcloud beta run domain-mappings describe
   --project="$PROJECT_ID" --domain perldoc.jp --region "$REGION"` で確認)
5. Cloudflare の proxy (オレンジ雲) を有効に戻し、SSL/TLS モードを
   **Full (strict)** にする
6. キャッシュルール: `/static/*` は Cache Everything + 長め TTL を推奨。
   HTML はデプロイ連動で変わるため既定のままでよい

証明書の更新で問題が出る場合の代替: Cloudflare Worker で
`https://<service>.run.app` へリバースプロキシする (ドメインマッピング不要)。

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

Cloudflare のキャッシュルールで `/static/*` を Cache Everything にする場合、
デプロイ後に古い docs.json が残らないよう TTL を短め (数時間程度) にするか、
デプロイ時にパージすること。

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
