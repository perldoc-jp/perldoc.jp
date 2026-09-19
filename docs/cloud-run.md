# Cloud Run 構成・セットアップ手順

perldoc.jp を Google Cloud Run で動かすための構成と、初期セットアップの手順。

## 構成の概要

```
[perldoc-jp/translation] --push--> workflow_dispatch ─┐
[perldoc-jp/perldoc.jp]  --push--------------------------┤
[schedule: 日次保険]  ───────────────────────────────────┤
                                                         v
                GitHub Actions / years ジョブ (deploy.yml)
                  translation の HEAD 解決
                  → data/years.pl を再導出し、差分があれば master へ commit
                  → 使うコミットと translation の SHA を出力
                                                         v
                GitHub Actions / deploy ジョブ (deploy.yml)
                  GHCR ログイン + WIF 認証
                  → translation取得 → SQLite構築 → データ生成
                  → テスト → Docker build
                  → GHCR と Artifact Registry へ同じイメージを push
                  → digest 照合 → GHCR から取得して smoke test
                  → Cloud Run deploy (digest 指定)
                                                         v
                GitHub Actions / purge ジョブ (deploy.yml)
                  トラフィックの移行を待つ
                  → Cloudflare のゾーンのキャッシュを purge
                                                         v
[ユーザー] → Cloudflare (Worker) → Cloud Run (asia-northeast1)
                           - min-instances=0 (無アクセス時のコストほぼゼロ)
                           - イメージに read-only SQLite + translation docs を焼き込み
                           - 非 root (uid 10001) で実行。実行時の書き込みは /tmp (tmpfs) のみ
                             (Xslate キャッシュと diff 用の一時ファイル)
```

- **イメージのビルドは GitHub Actions の GitHub-hosted runner で行う** (§11)。
  1 回のビルドで GHCR と Artifact Registry の両方へ push し、smoke test は GHCR から
  取得したイメージを検査する。Cloud Run へは Artifact Registry のイメージを digest
  指定でデプロイするので、検査したものとデプロイしたものが同一であることは、
  タグ名ではなく digest で確かめられる。
- **GitHub Actions の実行経路に Artifact Registry からの取得を置かない**。
  Artifact Registry から GitHub-hosted runner へレイヤやビルドキャッシュを引くと、
  そのたびに数百 MB 級のデータがインターネットへ出る data transfer out になる。
  ビルドキャッシュは Actions Cache (`type=gha`) に、smoke test の検査対象は GHCR に
  置き、Artifact Registry に対しては push と、digest 照合のためのメタデータ照会しか
  行わない。レイヤを引くのは同一リージョンの Cloud Run だけになる。
- **`data/years.pl` はビルドの前に更新する**。deploy.yml の years ジョブが
  `script/update-years.pl` で再導出し、差分があれば master へコミットしてから、
  その commit をソースにしてビルドする。ビルドの成果物を GitHub へ取り出す経路が
  無いため、更新はビルドの後ではなく前に行う。イメージはコミット済みの現物を
  読むので、イメージが読む years.pl とリポジトリにあるものは常に一致する。
- データ更新は「イメージ再ビルド + 再デプロイ」に一本化されている。翻訳データの
  取得と生成物の作成 (script/update.pl と script/create_data.pl) は Dockerfile の
  databuild ステージが担う。
- databuild の生成物は translation とソースの純関数として決定的に導出する。
  壁時計・ファイルの mtime・DB の行順 (インデックスの走査順で変わる) を
  結果に混ぜない。同じ入力からのビルドが同じバイト列になることで、アプリ
  だけの変更やベースイメージ更新で公開 JSON や feed の中身が動かない。
  版の選択は `PJP::M::PodFile` の `compare_version` / `get_latest` に一本化
  されていて、`static/docs.json` もこれに従う (= アプリが表示する版と常に
  一致する)。
- feed と年次統計の入力になる翻訳イベントは
  `PJP::M::Repository->commit_events` が git log の全走査 1 回で列挙する。
  現存ファイルごとの `git log -- <path>` を使わないのは、削除・rename された
  翻訳が見えないことに加え、translation が 2023 年に複数リポジトリを
  subtree merge で寄せ集めた経緯により、merge をまたぐ path の履歴が merge
  コミットに簡約されて翻訳者でなく merge 実行者が観測されてしまうため。
- 公開レスポンスは再デプロイまで変わらない (認証・セッション・個人化・時刻
  依存の生成が無い) ため、全パスの GET/HEAD の status 200 をエッジの二層で
  キャッシュする (§10 のエッジキャッシュ節)。外側は Workers Cache (Worker の
  手前。HIT では Worker 自体が起動しない)、内側は Worker の `fetch()` の
  `cf.cacheEverything` + `cacheTtlByStatus`。TTL は外側が 1 時間、内側が
  24 時間。内側は deploy.yml の purge ジョブが Deploy workflow の run のたびに
  ゾーンごと消すので、再デプロイ後に旧レスポンスが残るのは、purge できない
  外側の TTL の分、つまり purge から最大 1 時間になる。これは許容する。
  purge が失敗した run では、次に成功する run か内側の TTL までの最大
  24 時間に延びる。
- 翻訳の diff (`/docs/*/diff`) は GNU diff の外部コマンド化 (`PJP::HTMLDiff`)
  により perlfunc.pod 級の最悪ケースでも数秒以内に収まり、同じ比較の反復は
  エッジキャッシュに吸収される。diff は匿名入力で到達できる最も高コストな
  処理なので、Worker が `target` クエリを検証・正規化して、無関係なクエリ・
  等価なエンコード・重複 `target`・ヘッダー変化によるキャッシュキーの分割を
  防ぐ (worker/src/index.js)。外側の Workers Cache は同一キーの同時 MISS を
  データセンター内で 1 回の Worker 起動に集約する (request collapsing) ため、
  コールドな diff への同時アクセスも束ねられる。それでも異なる比較の初回計算、
  POP ごとのコールド MISS、eviction 後の再計算は Cloud Run に届くため、
  連続アクセス対策として Cloudflare のレートリミットルールの設定は引き続き
  推奨する (キャッシュはレートリミットやオリジン認証の代替ではない)。
- このサイトに存在したことのない path への既知のスキャンは、Worker が origin へ
  `fetch()` する前に path だけを見て 404 を返す (worker/src/index.js の
  `isScannerPath`)。Cloud Run の課金時間は 100 ms 単位の切り上げで、実処理が
  数 ms の 404 でも 1 リクエスト分の費用になるうえ、Worker は 200 以外を
  保存しない (§10) ため同じ path への再訪も毎回 origin に届く。判定は path の
  先頭一致の列挙ではなく、スキャンにしか現れない断片 (ルート直下の dot 名、
  任意位置の `.env` と `/wp-`、`.php` 末尾、Vite の `/@fs/`) で行い、一覧は
  短く保つ。アプリが将来使いうる path (`/.well-known/` 配下や `/api/` のような
  汎用名) やクローラの正当なリクエスト (`/sitemap.xml`) は含めない。アプリの
  ルートに当たって DB を引いた結果の 404 (`/pod/WWW::SourceForge` など) は
  この対象ではなく、従来どおり origin まで届く (issue #89)。
- `--allow-unauthenticated` のため `<service>.run.app` の URL 自体は公開のままで、
  Cloudflare を経由しない直アクセスにはエッジキャッシュもレートリミットも
  及ばない。直アクセス側の実質的な上限装置は max-instances (=3) である。ただし
  Cloud Run はトラフィックスパイクやリビジョン切替中の新旧重複などで設定値を
  一時的に超えることがあるため、絶対的なコスト上限ではなく主要な緩和策として
  扱う (完全に塞ぐには LB + ingress 制限が必要で、本構成のコスト方針とは
  釣り合わない)。
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

# 古いイメージの自動削除。30 日より古い version を消すが、最新 5 世代は
# 古くても残す (Keep と Delete の両方に当たる version は残る)
cat > /tmp/cleanup-policy.json <<'EOF'
[
  {
    "name": "keep-recent",
    "action": {"type": "Keep"},
    "mostRecentVersions": {"keepCount": 5}
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

Artifact Registry の version は manifest (digest) ごとに数えられる。deploy workflow と
§8 の手動ビルドが 1 回に push するのは単一の manifest 1 つで (11-1)、中身の同じビルドは
digest も同じになる (本番でも、1 つの digest に run ごとのタグが並んでいる)。この場合は
既存の version にタグが 1 つ増えるだけで、version は増えない。version が増えるのは
イメージの中身が変わったときだけなので、5 世代は中身の異なるイメージ 5 つにあたる。

`keep-recent` によって残るかどうかが変わるのは、30 日より古い version だけである。
30 日以内の version は世代数によらず残る。この規則は、更新の少ない期間が続いても
ロールバック先を 5 世代分残すためにある。それより前のイメージが要るときは、同じ digest が
GHCR に全世代残っている (11-2) ので、Artifact Registry へ push し直してから戻す
(「運用」のロールバック)。

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
は、組織ポリシーで自動付与が無効化されていない環境ではプロジェクトレベルの
`roles/editor` を持つ。自動付与の有無にかかわらず使わず、ロールを持たない専用 SA に固定する。

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
  --set-env-vars STARLET_MAX_WORKERS=4 \
  --cpu-boost \
  --timeout 60 \
  --port 8080 \
  --allow-unauthenticated
```

- `--concurrency` と `--set-env-vars STARLET_MAX_WORKERS=` は同じ値を渡す。
  Starlet のワーカー数と container concurrency が食い違うと、デフォルトの 80 の
  ままなら 4 ワーカーに大量のリクエストが詰まりタイムアウトの原因になる。
  Deploy workflow は `STARLET_MAX_WORKERS` を 1 つ持ち、両方へ渡している。
  `--set-env-vars` は列挙外の既存変数を消す。必要な環境変数はこの 1 つで
  完全列挙なので、dashboard 等で一時的に足された変数がデプロイをまたいで
  残らない (設定の情報源をこのコマンドに一本化する)。
- deploy.yml も `--image` と `--allow-unauthenticated` 以外は同じフラグ一式を毎回
  指定しているため、サービス設定はデプロイの実行順序に関わらず毎回同じ値に
  戻る。`--allow-unauthenticated` (= allUsers への run.invoker 付与) だけは
  この初回作成時のみで、以後のデプロイは IAM に触れない。デプロイ用 SA (§5) が
  IAM を書き換えられる権限を持たないためで、公開設定が消えた場合は自己修復
  されず §8 の確認で検出する。設定を変えるときは deploy.yml 側も合わせて
  更新すること。
- ただし、この自己修復が働くのは `gcloud run deploy` を実際に実行した run に
  限る。稼働中のリビジョンが指す digest とビルドした digest が一致する run は
  デプロイのステップ自体を飛ばすため (#85)、ダッシュボード等で変えられた設定は
  次に digest が変わる run まで元に戻らない。

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

# リビジョンの作成・トラフィック切替。IAM ポリシーの変更 (setIamPolicy) は
# 含まない。公開設定 (allUsers の run.invoker) は §4 の初回作成時に一度だけ
# 設定され、デプロイはそれに触れない
gcloud run services add-iam-policy-binding perldoc-jp \
  --project="$PROJECT_ID" --region="$REGION" \
  --member="serviceAccount:$SA" --role=roles/run.developer

# イメージの push (§11 で GitHub Actions がこの SA を名乗って行う) と、
# デプロイ時の読み取り。gcloud run deploy はデプロイ主体にも
# artifactregistry.repositories.downloadArtifacts を要求するが、writer は
# reader を含むのでこれ 1 つで足りる
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
# (workflow_dispatch で誤って別ブランチを選んでも、master 以外のコードは
# デプロイされない。master 自体の branch protection の有無とは独立)
#
# リポジトリ名ではなく repository_id / repository_owner_id (不変の数値ID) で
# 照合する。リポジトリが削除された後に同名で第三者が再取得する攻撃を防げる。
# attribute-condition は attribute-mapping を経由しない生の assertion.* を
# 直接参照できるが、SA バインディング側の principalSet はマッピング済みの
# attribute.* しか参照できないため、repository_id / repository_owner_id は
# mapping にも追加している
#
# workflow_ref 条件により、deploy.yml のリネーム・移動、リポジトリ名変更、
# デフォルトブランチ名変更のいずれでも認証が fail-closed で失敗する。
# その場合は --attribute-condition を新しい値で更新すること
gcloud iam workload-identity-pools providers create-oidc perldoc-jp \
  --project="$PROJECT_ID" \
  --location=global \
  --workload-identity-pool=github \
  --issuer-uri="https://token.actions.githubusercontent.com" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.repository_id=assertion.repository_id,attribute.repository_owner_id=assertion.repository_owner_id" \
  --attribute-condition="assertion.repository_id == '4013525' && assertion.repository_owner_id == '610796' && assertion.ref == 'refs/heads/master' && assertion.workflow_ref == 'perldoc-jp/perldoc.jp/.github/workflows/deploy.yml@refs/heads/master'"

gcloud iam service-accounts add-iam-policy-binding "$SA" \
  --project="$PROJECT_ID" \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/github/attribute.repository_id/4013525" \
  --role=roles/iam.workloadIdentityUser
```

### 6. 監査ログの有効化

WIF 経由の認証は (1) STS へのトークン交換 (`sts.googleapis.com`)、(2) 得られた
federated token でのデプロイ用 SA へのなりすまし (`iamcredentials.googleapis.com`
の `generateAccessToken`) の2段階で行われる。何かあった際に「どの GitHub Actions
run が認証したか」を追跡できるよう、両方の Data Access 監査ログを有効にする。

`iamcredentials.googleapis.com` は単独では Data Access ログを有効化できず、
`iam.googleapis.com` に対して有効化する必要がある。両サービスとも
`generateAccessToken` / `ExchangeToken` は `ADMIN_READ` 権限区分の監査対象。

```sh
gcloud projects get-iam-policy "$PROJECT_ID" --format=json > /tmp/iam-policy.json
cp /tmp/iam-policy.json /tmp/iam-policy.before-audit.json  # ロールバック用に保持

# /tmp/iam-policy.json の既存 "auditConfigs" (無ければ新規作成) に以下をマージする。
# "bindings" と "etag" には触れないこと
```

```json
{
  "auditConfigs": [
    {
      "service": "sts.googleapis.com",
      "auditLogConfigs": [{"logType": "ADMIN_READ"}]
    },
    {
      "service": "iam.googleapis.com",
      "auditLogConfigs": [{"logType": "ADMIN_READ"}]
    }
  ]
}
```

```sh
gcloud projects set-iam-policy "$PROJECT_ID" /tmp/iam-policy.json
```

ロールバックする場合、`/tmp/iam-policy.before-audit.json` をそのまま再適用しても
`etag` が古く競合で拒否される。`gcloud projects get-iam-policy` で最新のポリシーを
取り直し、`auditConfigs` だけを `/tmp/iam-policy.before-audit.json` の内容に戻して
から `set-iam-policy` すること。

Data Access ログは課金対象のため、有効化後にログ量を確認しておくこと。

### 7. GitHub リポジトリの Variables と Secrets

認証情報 (Cloudflare API トークン) に加え、Cloud Run の URL の構成要素になる
識別子と、それと相関する識別子も secret として扱う。URL は
`https://<SERVICE>-<PROJECT_NUMBER>.<REGION>.run.app` という決まった形なので、
構成要素が揃えば導ける。これは認証ではなく、公開 URL の発見可能性を下げる
補助的な対策で、URL が第三者に知られた時点で効果を失う (§10 の「run.app への
直アクセス」)。`SERVICE=perldoc-jp` と region は既にリポジトリ履歴で公開なので
secret にしない (今から隠しても効果がない)。

| 値 | 置き場所 |
|---|---|
| `GCP_PROJECT_ID` | environment `gcp-production` の secret |
| `GCP_PROJECT_NUMBER` | environment `gcp-production` の secret。ログに出る project number (service URL 内を含む) のマスクにも使われる |
| `CLOUDFLARE_ACCOUNT_ID` | repository variable (認証情報でも URL の構成要素でもない) |
| `CLOUD_RUN_URL` | environment `cloudflare-production` の secret (§10 の Worker のオリジン) |
| `CLOUDFLARE_API_TOKEN` | environment `cloudflare-production` の secret |
| `CLOUDFLARE_ZONE_ID` | repository variable (認証情報でも URL の構成要素でもない) |
| `CLOUDFLARE_CACHE_PURGE_TOKEN` | environment `cloudflare-cache-purge` の secret (§10 の purge ジョブ) |

environment `master-write` は secret を持たない。deploy.yml の years ジョブが
`data/years.pl` を master へ直接 push するので、その ref を master に限定する
目的だけで置く (yml 内の ref ガードは workflow_dispatch では yml ごと
差し替えられるので境界にならない。下の `CLOUDFLARE_API_TOKEN` の項と同じ理由)。

WIF provider (`projects/<PROJECT_NUMBER>/locations/global/workloadIdentityPools/github/providers/perldoc-jp`)
と SA email (`perldoc-jp-deployer@<PROJECT_ID>.iam.gserviceaccount.com`) は
deploy.yml が上記 2 つの secret から組み立てるため、個別には保存しない
(project number / ID の重複保存を避ける)。

GHCR への push (§11) も secret を増やさない。deploy ジョブに `packages: write` を
与えれば組み込みの `GITHUB_TOKEN` で push でき、イメージ名は `github.repository`
から組み立てる。

environment は workflow から参照されただけでも自動作成されるが、その場合は
branch policy の無い素通しになり、environment に secret が無ければ同名の
repository secret にフォールバックする。**4 つの environment は、branch policy を
付けた上で、secret を置く前に作る**。`master-write` は secret を持たないが、
作らずに参照されると branch policy 無しで自動作成され、master 限定の境界が
黙って無くなる。secret より先に作るのは、`gh secret set --env` が既存
environment の public key を取得して暗号化するため、environment が無ければ
404 で失敗するからでもある:

```sh
# environment の作成。custom branch policy を使う (protected_branches=true は
# 「保護ルールを持つ全ブランチを許可」の意味で、後からどこかのブランチに
# 保護ルールを足すと許可範囲も一緒に広がってしまう)
for env in gcp-production cloudflare-production cloudflare-cache-purge master-write; do
  gh api --method PUT "repos/perldoc-jp/perldoc.jp/environments/$env" \
    -F 'deployment_branch_policy[protected_branches]=false' \
    -F 'deployment_branch_policy[custom_branch_policies]=true'
  # master だけを許可する
  gh api --method POST \
    "repos/perldoc-jp/perldoc.jp/environments/$env/deployment-branch-policies" \
    -f name=master -f type=branch
done

# environment secret を置く (値の入力を求められる)
gh secret set GCP_PROJECT_ID --env gcp-production
gh secret set GCP_PROJECT_NUMBER --env gcp-production
gh secret set CLOUD_RUN_URL --env cloudflare-production
gh secret set CLOUDFLARE_API_TOKEN --env cloudflare-production
gh secret set CLOUDFLARE_CACHE_PURGE_TOKEN --env cloudflare-cache-purge

# 非機密の識別子は repository variable に置く
# (deploy-worker.yml が vars.CLOUDFLARE_ACCOUNT_ID を、deploy.yml の purge ジョブが
# vars.CLOUDFLARE_ZONE_ID を読む。Zone ID はダッシュボードのゾーンの Overview にある)
gh variable set CLOUDFLARE_ACCOUNT_ID
gh variable set CLOUDFLARE_ZONE_ID
```

GitHub の自動マスクは secret の完全一致に対して働く。変換・分割された値まで
マスクされる保証はないため、「secret に置いたからログへ出してよい」とは
しない (値そのものを出力しない設計を保つ)。

`CLOUDFLARE_API_TOKEN` は **Edit Cloudflare Workers テンプレートを使わず**、
Custom Token で作る。テンプレートは Workers KV / R2 / Routes / Tail /
Account Settings / User Details まで含み、この workflow に必要な範囲
(Worker script のアップロード・secret の登録・デプロイ) を大きく超える。

- Permissions: **Account / Workers Scripts / Edit** のみ
- Account Resources: 対象アカウント 1 つのみ
- account-owned token で作る (CI/CD 向けの service principal として公式に
  案内されており、user のライフサイクルから切り離せる)
- TTL (有効期限) を設定し、失効したら再発行する

この権限は account スコープで Worker 単位には絞れないため、漏れると同一
アカウントの全 Worker script を書き換えられる。environment
`cloudflare-production` の secret に置き、deployment branch policy を master に
限定することで、workflow_dispatch で他の ref を選んでもジョブ開始前に拒否される
(yml 内の ref ガードは、workflow_dispatch では実行者が選んだ ref の yml ごと
差し替えられるため防御にならない)。GCP 側で WIF の attribute-condition (§5) が
担っている境界の Cloudflare 版にあたる。

staging の Custom Domain の新規作成 (wrangler.jsonc の routes が使う
Attach Domain API) も、公式 API リファレンス上の必要権限は同じ
Workers Scripts Write とされる。初回の staging デプロイ (= 新規の
Attach) がこのトークンで成功することを検証する。権限エラーになった場合も
より広い権限のトークンには替えず、次の順で切り分ける:

1. トークンの Account Resources が対象アカウントを含むか
2. `CLOUDFLARE_ACCOUNT_ID` が正しいか
3. wrangler が呼んだ endpoint と 403 応答の内容
4. account-owned token 起因が疑われるなら、同じ Workers Scripts のみの
   user-owned token で試す
5. それでも失敗するなら wrangler の不具合として扱い、Custom Domain は
   ダッシュボードから作成する (トークンには権限を足さない)

参考: <https://developers.cloudflare.com/fundamentals/api/reference/template/>
(テンプレートの権限一覧)、
<https://developers.cloudflare.com/api/resources/workers/subresources/domains/methods/update/>
(Attach Domain の必要権限)、
<https://developers.cloudflare.com/fundamentals/api/get-started/account-owned-tokens/>
(account-owned token の位置付け)

`CLOUDFLARE_CACHE_PURGE_TOKEN` は deploy.yml の purge ジョブ (§10) だけが使う。
`CLOUDFLARE_API_TOKEN` に権限を足さず、別の Custom Token として作る。

- Permissions: **Zone / Cache Purge / Purge** のみ
- Zone Resources: perldoc.jp の 1 ゾーンのみ
- account-owned token で作る (上の参考の対応製品の一覧に Cache が含まれる)。
  purge が認証エラーになる場合は、同じ権限の user-owned token で切り分ける
- TTL (有効期限) を設定し、失効したら再発行する

この token が漏れても、できるのはゾーンのキャッシュを消すことだけで、Worker や
DNS は書き換えられない。消されるたびに origin への取得が増えるので、被害は
Cloud Run の費用と負荷になる。environment を `cloudflare-production` と分けるのは、
purge ジョブに Worker を書き換えられる token を見せないためである。失効や
権限の誤りで purge が失敗すると、purge ジョブが失敗として残る。

environment の作成と secret の登録はこの節冒頭のコマンドで行う。
deploy-worker.yml と deploy.yml の purge ジョブが動く前にそこまでを済ませて
おくこと。

WIF の attribute-condition と cloudflare-production の branch policy がどちらも
master に固定されているため、master に無いコードは GitHub Actions からは
デプロイできない。手元からビルドとデプロイを行う手順は §8 (Cloud Run) と
§10 (Worker)。

#### master の保護 (server-side)

WIF の attribute-condition (§5) と environment の branch policy (§7) は
「master から実行された」ことしか保証しない。master そのものは ruleset で
force push とブランチ削除を禁止する:

```sh
gh api --method POST repos/perldoc-jp/perldoc.jp/rulesets --input - <<'EOF'
{
  "name": "protect-master",
  "target": "branch",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["refs/heads/master"], "exclude": [] } },
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" }
  ]
}
EOF

# 確認 (master に適用されているルールの一覧)
gh api repos/perldoc-jp/perldoc.jp/rules/branches/master
```

pull request 必須ルールは入れていない。deploy.yml の years ジョブが
GITHUB_TOKEN で master へ直接 push するためで、PR 必須にするには push の PR 化か
bypass 用の専用 App が必要になり、単独メンテの merge も止まる。
したがって「write 権限を持つアカウントの侵害」に対する独立レビュー境界は
現状存在しない (承認 0 の PR 必須を足してもこの境界にはならない)。
メンテナが増えたときに required approvals + CODEOWNERS へ引き上げる。
ruleset の適用直後の Deploy workflow で、years ジョブの push が成功することを
確認する。同じ ruleset を translation リポジトリの master にも適用する
(GitHub App の private key を置くため。§9)。

### 8. 手動でのビルドとデプロイ

Deploy workflow を通さずに手元からビルドしてデプロイする手順。使うのは操作者自身の
gcloud 認証情報で、デプロイ用 SA (§5) は経由しない。

事前に `data/years.pl` が過去年 (2002〜) を含む現物になっていることを確認する。
`.dockerignore` に含まれないため作業ツリーの内容がそのままイメージに焼き込まれ、
databuild はこのファイルを再生成しない (「運用」の最後の項目を参照)。手元からの
ビルドでは years ジョブが走らないので、前年+当年を更新したい場合は
`script/update-years.pl` で先に再導出しておく (使い方は「運用」の
「data/years.pl の自動更新」)。

```sh
PROJECT_ID=perldoc-jp-XXXXXX
REGION=asia-northeast1
RUNTIME_SA=perldoc-jp-run@${PROJECT_ID}.iam.gserviceaccount.com
IMAGE=${REGION}-docker.pkg.dev/${PROJECT_ID}/perldoc-jp/app
TAG=manual-$(date +%Y%m%d%H%M%S)

# 一度だけ: docker が Artifact Registry へ push できるようにする
gcloud auth configure-docker "${REGION}-docker.pkg.dev"

# translation の HEAD に固定する (deploy.yml / test.yml と同じ)
TRANSLATION_COMMIT=$(git ls-remote https://github.com/perldoc-jp/translation.git refs/heads/master | cut -f1)

# Cloud Run は linux/amd64 のみ対応。Apple Silicon ではエミュレーションで動くため、
# 初回は CPAN 依存の XS ビルドを含めて時間がかかる
docker buildx build \
  --platform linux/amd64 \
  --target runtime \
  --build-arg "TRANSLATION_COMMIT=$TRANSLATION_COMMIT" \
  --provenance=false \
  --tag "$IMAGE:$TAG" \
  --push \
  .
```

- キャッシュは指定しない。CI のビルドキャッシュは GitHub の Actions Cache にあり、
  手元からは読めないので、この経路は毎回フルビルドになる。
- `--provenance=false` は deploy.yml に合わせたもの (11-1)。付けないと buildx が
  attestation を付け、manifest が image index になる。

本番同等の FS 制約で起動確認してからデプロイする (deploy.yml / test.yml の
smoke test と同じスクリプト)。ホスト側では Perl 5.38 以降を使用し、追加の
CPAN モジュールは必要ない。手元の daemon にイメージが無い状態で実行すると、
`docker run` が Artifact Registry から pull する。これはインターネットへの
data transfer out にあたるが、手動の経路でしか起きないので許容している:

```sh
./script/smoke-test.pl "$IMAGE:$TAG"
```

デプロイする。フラグは §4 および deploy.yml と同一で、`--image` だけが変わる
(`--allow-unauthenticated` は §4 の初回作成のみ):

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
  --set-env-vars STARLET_MAX_WORKERS=4 \
  --cpu-boost \
  --timeout 60 \
  --port 8080
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

# ランタイム SA はロールを持たないので、アプリケーションログが
# Cloud Logging に届いていることをここで確かめておく
gcloud logging read \
  'resource.type="cloud_run_revision" AND resource.labels.service_name="perldoc-jp"' \
  --project="$PROJECT_ID" --limit=20 --freshness=10m

# デプロイは IAM に触れないため、初回作成時 (§4) の allUsers run.invoker と、
# デプロイ用 SA の run.developer (§5) が残っていることを確認する。
# allUsers が消えていた場合は自己修復されない (§5 のコメント参照)
gcloud run services get-iam-policy perldoc-jp \
  --project="$PROJECT_ID" --region="$REGION"
```

`$URL` が空になる場合は `gcloud run deploy` が最後に表示する `Service URL:` を使う。

master へ merge すると以降は Deploy workflow が自動で回り、この手順は不要になる。

### 9. translation リポジトリ側の workflow

perldoc-jp/translation に以下を追加すると、翻訳の push で即座に再ビルドされる
(なくても日次の schedule で反映される)。通知は専用 GitHub App の installation
access token で deploy.yml を workflow_dispatch 起動する。
repository_dispatch + PAT を使わないのは、repository_dispatch が
`Contents: write` (リポジトリ内容の書き換え権限) を要求するため。
workflow_dispatch に必要なのは `Actions: write` だけで、これは workflow の
起動・再実行・停止はできてもコードは書き換えられない。

専用 GitHub App (perldoc-jp org で作成):

- Repository permissions: **Actions: Read and write** のみ (`Metadata: Read` は暗黙)
- Webhook: 無効
- インストール先: **Selected repositories で perldoc-jp/perldoc.jp の 1 つだけ**。
  private key が漏れたとき、その App の全 installation に対して token を
  発行できるため、汎用 App を流用せず影響範囲をこの 1 リポジトリに限る

translation 側の設定:

- environment `perldoc-jp-notify` を作り、deployment branch policy を master のみに
  する (§7 の cloudflare-production と同じ手順・同じ理由)
- App の private key を同 environment の secret `PERLDOC_JP_APP_PRIVATE_KEY` に置く
- App の Client ID (公開識別子) を同 environment の variable
  `PERLDOC_JP_APP_CLIENT_ID` に置く

```yaml
# .github/workflows/notify-perldoc-jp.yml
name: Notify perldoc.jp

on:
  push:
    branches:
      - master

# 組み込み GITHUB_TOKEN は使わないので全権限を落とす
permissions: {}

jobs:
  notify:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    environment: perldoc-jp-notify

    steps:
      # private key を読む外部 action なのでコミット SHA にピン留めする
      - name: Create installation token
        id: app-token
        uses: actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1 # v3.2.0
        with:
          client-id: ${{ vars.PERLDOC_JP_APP_CLIENT_ID }}
          private-key: ${{ secrets.PERLDOC_JP_APP_PRIVATE_KEY }}
          owner: perldoc-jp
          repositories: perldoc.jp
          permission-actions: write

      # token は 1 時間で失効し、ジョブ終了時に action が revoke する。
      # payload は渡さない (perldoc.jp 側は translation の HEAD を git ls-remote で
      # 自分で解決するため、通知の中身を信用する必要がない)
      - name: Dispatch perldoc.jp deployment
        env:
          GH_TOKEN: ${{ steps.app-token.outputs.token }}
        run: |
          gh api --method POST \
            repos/perldoc-jp/perldoc.jp/actions/workflows/deploy.yml/dispatches \
            -f ref=master
```

App token (`Actions: write`) が侵害されたときにできることは dispatch 専用では
ない。正確には次のとおり:

- deploy.yml / deploy-worker.yml の dispatch と、レビュー済み master の再デプロイ
- 既存 run の再実行 (初回実行から 30 日以内。元の actor の権限・元の SHA/ref で
  走る)・キャンセル、workflow の停止・再開、run / artifact の操作
- deploy.yml 経由での years ジョブの起動 (= レビュー済みコードが生成する
  派生データ data/years.pl の master へのコミットまでは到達する)
- `ref` は API 上 master 以外の既存 ref も指定できる (`-f ref=master` は
  呼び出し側の慣行であって token の制約ではない)。ただし別 ref への dispatch は、
  GCP 側は WIF の attribute-condition が、GCP / Cloudflare の environment secret
  は branch policy が master 限定のため拒否する。App は Contents 権限を
  持たないので、ブランチもファイルも直接は作成・変更できない
- update-cpanfile-snapshot (contents: write) は workflow_dispatch を持たないため
  新規には起動できない

private key は installation token と違い長期の資格情報。定期的にローテーション
し (App 設定で新しい鍵を追加 → translation の secret を差し替え → 旧鍵を削除)、
漏えい時は App 設定から鍵を即失効する。private key を置く translation
リポジトリの master と `.github/workflows/` も、perldoc.jp と同じ ruleset
(force-push / 削除禁止。§7) で保護する。

根拠 (公式ドキュメント):

- <https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/making-authenticated-api-requests-with-a-github-app-in-a-github-actions-workflow>
- <https://docs.github.com/en/rest/actions/workflows#create-a-workflow-dispatch-event> (必要権限は `Actions: write`)
- <https://docs.github.com/en/actions/how-tos/manage-workflow-runs/re-run-workflows-and-jobs> (再実行の 30 日制限と元 actor / ref の再利用)

### 10. Cloudflare (Worker で Cloud Run にリバースプロキシする)

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

実装は `worker/src/index.js`、設定は `worker/wrangler.jsonc`。master への push で
`worker/` が変わったときだけ `.github/workflows/deploy-worker.yml` がデプロイする。

- `X-Forwarded-Host` の付与は必須。`Amon2::Web::redirect` は `Plack::Request->base`
  (= `HTTP_HOST` 由来) で `Location` の絶対 URL を組むため、これが無いと `/func/*`
  などの正規化リダイレクトが `Location: https://<service>.run.app/...` を返す。
  app.psgi の `Plack::Middleware::ReverseProxy` がこのヘッダを `HTTP_HOST` に戻す
- `X-Forwarded-For` は `CF-Connecting-IP` から付け直しているが、これで
  `REMOTE_ADDR` が実クライアント IP になるわけではない。Cloud Run のフロントエンドが
  受け取った値の末尾に自分から見た接続元 (= Cloudflare の egress IP) を足し、
  `ReverseProxy` は最後の値を採るため。実クライアント IP はヘッダの先頭に残るだけ
- オリジンの URL は wrangler.jsonc に置かず、デプロイ時に `scripts/deploy.sh` が
  Worker の secret として注入する (`--secrets-file`)。値は environment
  `cloudflare-production` の secret `CLOUD_RUN_URL` (§7)。Cloudflare 側でも
  暗号化 binding になり、dashboard や Wrangler から値は表示されない。
  形式は `worker/src/origin.js` が
  検証する (https / `.run.app` のホスト名 / 資格情報・ポート・パス・クエリ無し)。
  Worker 本体とデプロイ手順の両方が同じ検証を通すので、設定ミスはデプロイの時点で
  落ちる
- origin 側の障害や設定ミスは 502 にして、`cf-ray`・パス・例外の種類を
  構造化ログに出す。ログは Workers Logs で見る (wrangler.jsonc の `observability`。
  正常なリクエスト 1 件ごとのログは保存件数を消費するだけなので切ってある)

`CLOUD_RUN_URL` に入れる値:

```sh
gcloud run services describe perldoc-jp \
  --project="$PROJECT_ID" --region="$REGION" --format='value(status.url)'
```

手元からデプロイする場合の手順。wrangler は `worker/package.json` の
exact な devDependency で、`worker/package-lock.json` が依存グラフ全体を固定する。
バージョンを変えるときは lockfile も一緒に更新すること。staging へも同じブロックで、
最後を `./scripts/deploy.sh staging` に変えるだけ。

**インストールはトークンを渡さない状態で行う** (`npm ci` を実行してから
`CLOUDFLARE_API_TOKEN` を読み込む)。依存の install フックはインストール時の
環境変数を読めるため、トークンを置いたまま入れると依存の乗っ取りがそのまま
トークンの奪取になる。以下は **bash** で実行する (read の挙動が shell で
異なる)。subshell に閉じているので、成功・失敗のどちらでも token と ORIGIN は
親 shell に残らない:

```bash
(
  set -euo pipefail
  cd worker
  npm ci   # トークンを読み込む前に入れる (install フックに読ませない)

  export CLOUDFLARE_ACCOUNT_ID=...   # 非機密 (§7)

  # トークンは実値をコマンドラインに書かない (shell history に残る)。
  # パスワードマネージャから取得し、echo なしで貼り付ける
  printf 'CLOUDFLARE_API_TOKEN: ' >&2
  IFS= read -r -s CLOUDFLARE_API_TOKEN
  printf '\n' >&2
  export CLOUDFLARE_API_TOKEN

  ORIGIN=$(gcloud run services describe perldoc-jp \
    --project="$PROJECT_ID" --region="$REGION" --format='value(status.url)')
  export ORIGIN

  ./scripts/deploy.sh production
)
```

`scripts/deploy.sh` が wrangler の argv (絶対 `--config`・environment selector・
検証済み `ORIGIN` の注入・`--offline`) を組み立てる。`production` は
`wrangler.jsonc` の top-level、`staging` は named environment を指す。
`--env` を省くと `CLOUDFLARE_ENV` で環境が選ばれてしまうため、selector は
必ず明示している。

ここで `wrangler login` (OAuth) を使わないのは、login の既定スコープが
d1 / pages / ssl_certs / queues など Workers Scripts を大きく超える write を
含み、token が refresh token ごと平文の
`~/Library/Preferences/.wrangler/config/default.toml` に永続化される
(自動更新されるため実質無期限) ためである。上の手順が `npm ci` をトークンより
先に行うのと同じ脅威モデル (手元の依存・マルウェアによる資格情報の奪取) に対しては、
ディスクに残らない Workers Scripts のみのトークンのほうが安全になる。
取り回しを優先して login を使う場合も
`wrangler login --scopes account:read user:read workers_scripts:write` で
絞り、作業が終わったら `wrangler logout` でセッションを破棄すること。
なお wrangler は `CLOUDFLARE_API_TOKEN` が無いと手元の OAuth セッションで
認証するため、過去に login したままの環境では意図しない資格情報でデプロイ
され得る。`wrangler whoami` で状態を確認し、残っているセッションは
logout しておく。

Worker の通常変数は `wrangler.jsonc` で、secret (ORIGIN) は `scripts/deploy.sh` で
定義する。dashboard で追加した通常変数は次回のデプロイで消える。secret は
デプロイごとに `--secrets-file` で再登録され、列挙外の既存 secret は消えない。

#### DNS

- `perldoc.jp` (apex) は Worker の **Custom Domain** として登録する。DNS レコードと
  証明書は Cloudflare が自動で作る。Workers の route にプレースホルダの
  `AAAA 100::` を置く方式は Cloudflare が非推奨としている。apex は wrangler.jsonc の
  routes には書かずダッシュボードで登録する。`wrangler deploy` が DNS の切り替えを
  伴うと事故になるため (staging は壊れても影響がないので `env.staging` の routes で
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

#### エッジキャッシュ (Workers Cache と fetch の cf 設定)

エッジのキャッシュポリシーは Worker 側で決め、二層で構成する
(worker/src/index.js の `WORKERS_CACHE_TTL` / `ORIGIN_CACHE_TTL`):

- **外側: Workers Cache** (<https://developers.cloudflare.com/workers/cache/>)。
  wrangler.jsonc の `cache.enabled` で有効化する、Worker の手前のキャッシュ層。
  HIT では Worker 自体が起動しない。保持の可否と TTL は Worker が全レスポンスへ
  明示する `Cloudflare-CDN-Cache-Control` ヘッダーで制御し、GET/HEAD の 200 は
  `max-age=3600`、それ以外は `no-store` を付ける。**無指定はオプトアウトに
  ならず**、RFC 9111 のヒューリスティック (404 も 180 秒保持など) が適用される。
  したがって `cache.enabled` を残したままヘッダー側だけを消すわけにはいかない。
  このヘッダーはエッジで消費されクライアントへは届かない。同一キーの同時
  MISS はデータセンター内で 1 回の Worker 起動に集約される (request
  collapsing)。キャッシュは Worker 単位かつ Worker の version 単位
  (`cross_version_cache` は既定の false) なので、Worker のデプロイごとに空から
  始まる。Cloud Run 側のデプロイでは消えない。
- **内側: `fetch()` の cf 設定**。Worker は全パスの GET/HEAD のサブリクエストに

  ```js
  cf: {
    cacheEverything: true,
    cacheTtlByStatus: { "200": 86400, "201-599": -1 },
  }
  ```

  を付けて Cloud Run へ `fetch()` する。status 200 だけが最大 24 時間エッジに残り、
  404 / 503 / 3xx と Worker 自身の 400 / 502 は保存されない (負数は「保存
  しない」の意味。`0` は即時失効なので使わない)。

役割分担: 外側は性能最適化 (HIT で Worker の起動と CPU を省き、同時 MISS を
束ねる)、内側はオリジンを守る最後の層。外側のキーにはクライアントが自由に
変えられるヘッダー (後述) が含まれるためキー分割で MISS を強制できるが、
そうして Worker まで届いた変種も、内側では Worker が正規化した上流 URL の
キーに寄って HIT する。**外側があるからといって内側を外すわけにはいかない**。

ダッシュボードの Cache Rules に同じルールを重ねない。Workers Cache には
ゾーンの Cache Rules / Page Rules / cache level 設定がそもそも一切適用されず、
内側の `cf` 設定も Cache Rules や Page Rules より優先される (内側の優先は
compatibility date が `request_cf_overrides_cache_rules` の既定有効日
2025-04-02 以降であることが前提。wrangler.jsonc は 2026-07-25)。

TTL を決める場所:

- ブラウザー向け TTL は app.psgi が付ける `Cache-Control` が唯一の情報源
  (`/static/docs.json` と `/static/rss/` は 2 時間、それ以外の `/static/*` と
  `/favicon.ico` は 4 時間。動的 HTML には付けない)。Worker はレスポンスへ
  `Cache-Control` を足さない (`Cloudflare-CDN-Cache-Control` はエッジ専用で、
  クライアントへは届かない)。
- 外側のエッジ TTL は Worker が付ける `Cloudflare-CDN-Cache-Control` が唯一の
  情報源 (全 200 で 1 時間)。オリジンの `Cache-Control` より優先され、
  オリジンが誤って `Cloudflare-CDN-Cache-Control` を返しても Worker が
  上書きする。
- 内側のエッジ TTL は Worker の `cf` 設定が唯一の情報源 (全 200 で 24 時間)。
- 再デプロイ後の残留は、purge から外側の TTL までの最大 1 時間 (構成の概要)。
  内側は deploy.yml の purge ジョブが run のたびに消すので、内側の TTL は
  この予算に入らない。内側の TTL は、purge が失敗したときに古い応答が残る
  時間の上限を決める。外側は purge できないので、外側の TTL を延ばすと
  この予算がそのまま延びる。

この予算は平常時のもの。Worker のエラー時は、外側が失効済みの保存応答を
`Cf-Cache-Status: STALE` として配る。ヘッダーに `stale-if-error` を指定して
いないため、この stale 配信に時間の上限は無く、エントリが purge・eviction
されるか Worker が回復するまで続き得る。エラーを返すよりよいのでこれを許容する
(`UPDATING` は `stale-while-revalidate` を明示した場合だけの状態で、現在の
ヘッダーでは発生しない)。鮮度に有限の上限が必要になったら、`stale-if-error=N`
を明示してその値をテストで固定する。

裏返しとして、公開 URL が 200 を返し続けることは障害が無いことの証明に
ならない。障害の検知は `Cf-Cache-Status: STALE` の有無と Workers Logs
(proxy failed の console.error) で行い、古い応答を止める必要があれば purge する。
内側は「運用」の手順で手から purge できる。外側の purge API は「purge について」の
とおり未配線なので、外側は Worker の再デプロイによる version 分離が実質の
purge になる。

内側のキャッシュキーは Cloudflare の既定 (サブリクエスト URL 全体と、`Origin` /
method override 系 / `X-Forwarded-Host` などの一部ヘッダー) を使う。
`cf.cacheKey` は Enterprise 限定なので使わない。この前提で:

- 一般ルートはクエリ全体がキーに残る。`/about?nonce=1` と `?nonce=2` は
  別キーになり、変種の初回はオリジンへ届く。アプリは
  クエリを意味に使う余地がある (`/search?q=`、tmpl/pod.tt の `c().req.uri()`
  による Source link) ため、一般ルートのクエリは推測で削らない。
  ダッシュボードの「Ignore Query String」も使わない (diff の `target` まで
  キーから消え、異なる差分の混同 = キャッシュ汚染になる)。
- diff だけは Worker が上流クエリを再構築する。空でない `target` 1 個だけを
  正規化してキーに残し、未知パラメーターは受理しつつ上流 URL から除く。
  重複 `target` とエスケープ (`%`) 入りの diff 形パスは 400 で止め、
  キー分割や Worker/Plack のパーサー差を突いたすり抜けを上流に到達させない。
- キャッシュキーを分割・迂回できるリクエストヘッダー (`Origin`、method
  override 系、`Cache-Control: no-cache`、`Pragma`、`Cookie`、
  `Authorization` など) は、キャッシュ対象の GET/HEAD では Worker が上流へ
  渡さない。`X-Forwarded-Host` は Worker が信頼値で確定させるため、同じ
  run.app を叩く本番と staging のキャッシュはホスト名ごとに分かれる。

外側 (Workers Cache) のキャッシュキーは Cloudflare が固定で決める:
path + クエリ (パラメーターの順序も区別)、Worker の version、それに
method override 系・URL rewrite 系・forwarding 系のリクエストヘッダー。
ホスト名はキーに含まれないが、本番と staging は別 Worker
(perldoc-jp / perldoc-jp-staging) で、キャッシュ自体が Worker 単位に
分かれているため混ざらない。diff のクエリ正規化は Worker の中の処理なので
外側キーには反映されず、等価表現の変種は外側では別キーになる。それらは
Worker を起動させるだけで、正規化後の内側キーへ寄って HIT するため
Cloud Run には届かない (Worker の起動は現状の全リクエストと同じ費用)。

purge について: 内側は deploy.yml の purge ジョブが、ゾーンの Purge Everything
(`worker/scripts/purge-cache.sh`) で消す。ゾーンごと消すのは、内側のエントリが
上流サブリクエストの run.app URL を基準に保持されていて、perldoc.jp の URL を
指定した単一ファイル purge では消えないためである。Purge Everything が
このエントリまで消すことは Cloudflare のドキュメントに明記が無いので、構築時に
「動作確認」の手順で確かめる。Purge Everything は Free プランで使え、レート制限は
5 回/分である。

purge ジョブは次のように動く。

- Deploy workflow の run のたびに purge する。deploy ジョブが digest の一致で
  デプロイを飛ばした run も含む。デプロイした run が purge の前に後続の run に
  キャンセルされると、後続の run は同じ digest を見てデプロイを飛ばすので、
  「デプロイした run だけが purge する」条件では purge が抜ける。毎回 purge する
  費用は小さい。purge しなくてもエントリは 24 時間で失効するので、日次の purge が
  増やす origin への取得は、URL ごとに 1 日あたり高々 1 回である。
- purge の前に 120 秒待つ。Cloud Run のトラフィックの切り替えは即時ではなく、
  移行のあいだは旧リビジョンにもリクエストが届きうる。デプロイの直後に purge
  すると、旧リビジョンの応答が空になった内側へ入り、次の purge まで残りうる。
  移行にかかる時間は公表されていないので、120 秒は実測に基づかない余裕である。
- deploy ジョブが失敗した run では purge しない。origin が壊れているかも
  しれないときに、origin の代わりに応答できるキャッシュを捨てないためである。
- purge が失敗すると purge ジョブが失敗として残る。Re-run failed jobs で
  purge ジョブだけを再実行できる。放置しても、次に成功する run か内側の TTL の
  24 時間で解消する。

外側には Worker 内から呼ぶ purge API (`ctx.cache.purge`) があるが使っていない
(呼び出し経路を作ること自体が新しい入口になる)。外側は 1 時間の自然失効に
任せる。Worker のデプロイは外側を version 分離で空にするが、内側は消さない。

**将来、認証・セッション・Cookie・ユーザー別表示・時刻依存のルートを追加する
場合は、同じ変更で Worker がそのルートへ (1) `cf` のキャッシュ設定を付けない
(2) `Cloudflare-CDN-Cache-Control: no-store` を付ける、の両方を行うこと。**
内側は `cacheEverything` と明示的な TTL の組がオリジンの `Set-Cookie` や
`Cache-Control: private` より強く働き得るため、アプリ側のレスポンス
ヘッダーだけでは共有キャッシュからの opt-out にならない。外側は
`Set-Cookie` 付き応答を保存しないが、これに頼らず明示する。

関連するゾーン設定 (Caching → Configuration):

- `Browser Cache TTL`: **Respect Existing Headers**。固定値だと app.psgi の
  `Cache-Control` を上書きする (既定は 4 時間)
- `Caching Level`: Standard
- `Development Mode`: OFF (ON の間、内側 = ゾーンのキャッシュがされない。
  外側の Workers Cache は zoneless なので影響を受けない)
- Page Rules は使わない (Worker の `cf` 設定と重なる)
- Rules → Settings の `Normalize incoming URLs`: **On**、type は `RFC-3986`
  (どちらも既定値)。`%70erl` → `perl` のような unreserved エンコードを
  Worker より前に canonical な URL へ寄せる。Worker は `%` を含む diff 形
  パスを 400 で止めるため、この設定はキャッシュ回避防止の必須条件ではなく、
  等価な URL 表現を寄せて 400 を減らすための互換性設定

デプロイ後の `cf-cache-status` は外側 (Workers Cache) の状態を返す
(HIT / MISS / BYPASS / DYNAMIC など。HIT では Worker が起動していない)。
`DYNAMIC` のままのときに疑う順は (1) wrangler.jsonc の `cache.enabled` が
デプロイに入っていない (2) Worker が `Cloudflare-CDN-Cache-Control` を
付けていない (デプロイ漏れ)。Workers Cache は zoneless なので、Development
Mode を含むゾーン設定は外側の説明にならない。内側の層を調べるとき
(外側を無効にした切り分けなど) は、(3) Development Mode が ON (4) Worker の
`cf` 設定のデプロイ漏れ (5) compatibility date が古く Cache Rules 側が
優先されている、を疑う。`MISS` → `HIT` の確認手順は
「動作確認」のとおり。

#### SSL/TLS

- `Always Use HTTPS`: **有効**。HTTP で来たリクエストをエッジで HTTPS へ 301 する
- `Minimum TLS Version`: **1.2**
- perldoc.jp 側の証明書は Universal SSL (`*.perldoc.jp` と apex) が担う
- **SSL/TLS の暗号化モード (Flexible / Full / Full strict) は本構成には影響しない**。
  Worker の `fetch()` は Worker ランタイムからオリジンへの独立した HTTPS リクエストで、
  ゾーンの暗号化モードに従わない。run.app の証明書は Google が管理するため
  検証も常に成立する
- 暗号化モードの `Automatic mode` (Cloudflare が定期スキャンでモードを決める) が
  有効だと、スキャンのたびにモードが変わり得る。上記のとおり本構成には影響しない
  設定なので実害は無いが、意図しない変更が混ざるのを避けたいなら手動に固定する
- `HSTS` は未設定。有効にすると HTTP でのアクセス手段を長期間放棄することになるため、
  `Always Use HTTPS` が安定してから別途判断する

#### 動作確認 (staging.perldoc.jp)

本番の apex に触らないまま構成をまるごと検証する手順。`staging.perldoc.jp` を Worker の
Custom Domain にすれば、ゾーン設定 (URL 正規化・Redirect Rules・SSL/TLS) を通った
本番と同じ経路で挙動を確かめられる。`workers.dev` のサブドメインはゾーンの
設定をどれも通らないため、キャッシュと正規化の確認には足りない。

1. Cloud Run にデプロイしておく (§8)
2. staging の Worker をデプロイする。「手元からデプロイする場合」の bash
   ブロックを、最後だけ `./scripts/deploy.sh staging` に変えて実行する。
   `wrangler.jsonc` の `env.staging` が `staging.perldoc.jp` を Custom Domain
   として作り、`NOINDEX` も設定ファイル側で与える (Worker が
   `X-Robots-Tag: noindex, nofollow` を足し、本番と重複した内容が検索結果に
   出るのを防ぐ)
3. 確認する:
   ```sh
   BASE=https://staging.perldoc.jp

   # アプリの主要な経路 (script/smoke-test.pl と同じ観点)
   curl -fsS "$BASE/" | grep 'perldoc.jp' > /dev/null
   curl -fsS -o /dev/null "$BASE/docs/perl/perl.pod"
   curl -fsS "$BASE/translators" | grep '年</h2>' > /dev/null
   curl -fsS "$BASE/static/docs.json" | grep 'Acme::Bleach' > /dev/null
   curl -fsS -o /dev/null "$BASE/favicon.ico"

   # X-Forwarded-Host が反映されていること。/chomp は /func/chomp へのリダイレクトなので、
   # ここに run.app が出たら Worker 側の不備 (/func/chomp 自体は 200 なので使えない)
   curl -sS -o /dev/null -D - "$BASE/chomp" | grep -i '^location:'

   # ブラウザー向けの Cache-Control はオリジン由来
   # (docs.json は 2 時間、css は 4 時間)。動的 HTML には現れない
   curl -sS -o /dev/null -D - "$BASE/static/docs.json"     | grep -i '^cache-control:'
   curl -sS -o /dev/null -D - "$BASE/static/css/style.css" | grep -i '^cache-control:'
   curl -sS -o /dev/null -D - "$BASE/" | grep -i '^cache-control:' \
     || echo 'HTML に Cache-Control なし (期待どおり)'

   # 全パスの 200 が 2 回目で HIT になること (2 回目の HIT は外側の
   # Workers Cache で、Worker は起動していない)。HIT では Age が現れ、
   # 時間経過で増える
   for path in / /docs/perl/perl.pod /static/docs.json /static/css/style.css; do
     curl -sS -o /dev/null -D - "$BASE$path" | grep -i '^cf-cache-status:'
     curl -sS -o /dev/null -D - "$BASE$path" | grep -iE '^(cf-cache-status|age):'
   done

   # エッジ制御ヘッダーがクライアントへ漏れないこと (エッジで消費される)。
   # 出てきたら Workers Cache が有効になっていない構成を疑う
   curl -sS -o /dev/null -D - "$BASE/" | grep -i '^cloudflare-cdn-cache-control:' \
     || echo 'Cloudflare-CDN-Cache-Control なし (期待どおり)'

   # diff も 2 回目が HIT。GET で充填したキャッシュは HEAD でも HIT になり
   # 本文を返さない
   DIFF_URL="$BASE/docs/perl/5.38.0/perl.pod/diff?target=perl%2F5.36.0%2Fperl.pod"
   curl -sS -o /dev/null -D - "$DIFF_URL" | grep -iE '^(cf-cache-status|age):'
   curl -sS -o /dev/null -D - "$DIFF_URL" | grep -iE '^(cf-cache-status|age):'
   curl -sS -I "$DIFF_URL" -o /dev/null -D - | grep -iE '^(cf-cache-status|age):'

   # diff の未知パラメーターは Worker がキーから除き、内側では同じキャッシュへ
   # 寄る。外側 (Workers Cache) のキーはクエリをそのまま含むため、この変種は
   # 外側では MISS になり得る。その場合も Worker 経由で内側の HIT に寄り、
   # Cloud Run には届かない (Cloud Run ログ確認まで見れば合格)。
   # 一般ルートのクエリ変種が別キー (MISS) になるのは仕様
   curl -sS -o /dev/null -D - "$DIFF_URL&nonce=1" | grep -iE '^(cf-cache-status|age):'

   # 重複 target は Worker の 400 で Cloud Run に届かない
   curl -sS -o /dev/null -w '%{http_code}\n' \
     "$DIFF_URL&target=perl%2F5.36.0%2Fperl.pod"

   # キー分割・再検証・認証ヘッダーを送っても diff の再計算を強制できない。
   # 外側 (Workers Cache) は Authorization などで BYPASS / MISS になり得るが、
   # その場合も Worker がヘッダーを一掃した内側で HIT し、Cloud Run には
   # 届かない。ここの表示が HIT 以外でも、後述の Cloud Run ログ確認で
   # diff 計算が発生していないことまで見れば合格
   curl -sS -o /dev/null -D - \
     -H 'Origin: https://attacker.example' \
     -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' \
     -H 'Cookie: cache-bust=1' -H 'Authorization: Bearer cache-bust' \
     "$DIFF_URL" | grep -iE '^(cf-cache-status|age):'

   # エスケープ入りの diff 形パスは 400 (非正規化キーでの再計算にならない)
   curl -sS -o /dev/null -w '%{http_code}\n' \
     "$BASE/docs/perl%2F5.38.0/perl.pod/diff?target=perl%2F5.36.0%2Fperl.pod"

   # unreserved エンコードはゾーンの URL 正規化で canonical に寄って HIT になるか、
   # 正規化が無効なら Worker の 400 になる。200 のまま毎回オリジンで再計算
   # (DYNAMIC や MISS の連続) されたら不合格
   curl -sS -o /dev/null -D - \
     "$BASE/docs/%70erl/5.38.0/perl.pod/diff?target=perl%2F5.36.0%2Fperl.pod" \
     | grep -iE '^(HTTP/|cf-cache-status:|age:)'

   # 404 と 3xx は保持されない (2 回目も HIT にならない)
   curl -sS -o /dev/null -D - "$BASE/docs/perl/no-such.pod" | grep -iE '^(HTTP/|cf-cache-status:)'
   curl -sS -o /dev/null -D - "$BASE/docs/perl/no-such.pod" | grep -iE '^(HTTP/|cf-cache-status:)'
   curl -sS -o /dev/null -D - "$BASE/chomp" | grep -iE '^(HTTP/|cf-cache-status:)'

   # staging がクロール除けになっていること (キャッシュ HIT でも毎回付く)
   curl -sS -o /dev/null -D - "$BASE/" | grep -i '^x-robots-tag:'
   ```

   異なる比較対象の分離も確認する (A を再取得して B の本文が返らないこと):
   ```sh
   curl -fsS "$BASE/docs/perl/5.38.0/perl.pod/diff?target=perl%2F5.36.0%2Fperl.pod" \
     -o /tmp/perldoc-diff-a.html
   curl -fsS "$BASE/docs/perl/5.38.0/perl.pod/diff?target=perl%2F5.34.0%2Fperl.pod" \
     -o /tmp/perldoc-diff-b.html
   shasum -a 256 /tmp/perldoc-diff-a.html /tmp/perldoc-diff-b.html
   ```

   Cloud Run 側でも軽減を確認する: 同じ URL を短時間に複数回送り、Cloudflare で
   後続が `HIT` になる間、Cloud Run のリクエストログにはキャッシュ充填分だけが
   届いていること (HIT と同数のリクエストや diff 計算が発生していないこと) を
   見る。

   purge が内側のキャッシュまで消すことを確認する。内側の状態はクライアントから
   直接は見えない (`cf-cache-status` は外側の状態を返す) ので、外側のキーだけを
   変えるリクエストヘッダーで外側を MISS させ、内側の HIT を `age` の有無で見る。
   method override 系のヘッダーは外側のキーに含まれる一方、Worker が上流へ
   渡さないので内側のキーには入らない:
   ```sh
   # 他のリクエストと重ならない URL にする (一般ルートのクエリはキーに残る)
   URL="$BASE/about?purge-check=$(date +%s)"
   probe() {
     curl -sS -o /dev/null -D - -H "X-HTTP-Method-Override: $1" "$URL" \
       | grep -iE '^(cf-cache-status|age):'
   }

   probe a   # 外側 MISS・内側 MISS。Cloud Run のリクエストログに 1 件届く
   sleep 15  # 書き込んだ直後 (2 秒後) の再取得は、内側でも MISS になることがある
   probe b   # 外側 MISS で age が付く = 内側 HIT。Cloud Run には届かない
   ```
   ここで purge する (「運用」の「エッジキャッシュを手で purge する」)。
   ```sh
   probe c   # 外側 MISS で age が無く、Cloud Run に 2 件目が届けば内側は消えている
   ```
   `probe c` に `age` が付いたままなら、ゾーンの purge は内側に届いていない。
   その場合は、内側の TTL を 24 時間にしておく前提 (purge が鮮度を保つ) が
   成り立たないので、worker/src/index.js の `ORIGIN_CACHE_TTL` を外側と同じ
   1 時間にする。

   症状から切り分ける:
   - `/chomp` の `Location` に run.app が出る → Worker が `X-Forwarded-Host` を
     付けていない
   - 200 が `DYNAMIC` のまま → wrangler.jsonc の `cache.enabled` か
     `Cloudflare-CDN-Cache-Control` がデプロイに入っていない (Development
     Mode は zoneless な外側には影響しない) / (内側の層は) Development Mode が
     ON・Worker の `cf` 設定の漏れ・compatibility date
     (「エッジキャッシュ」節の切り分け順)
   - `/favicon.ico` が 404、`Cache-Control` が付かない → デプロイされているイメージが
     古い (Worker や Cloudflare の設定ではない)
4. 検証が済んだら片付ける (残すと staging.perldoc.jp という公開入口と Workers の
   枠を無駄に使う)。削除も Cloudflare の認証情報と worker ディレクトリを要する
   ため、デプロイと同じ形の bash subshell で自己完結させる。削除後、Custom
   Domain が Cloudflare 側に残っていたら合わせて外す:
   ```bash
   (
     set -euo pipefail
     cd worker

     export CLOUDFLARE_ACCOUNT_ID=...

     printf 'CLOUDFLARE_API_TOKEN: ' >&2
     IFS= read -r -s CLOUDFLARE_API_TOKEN
     printf '\n' >&2
     export CLOUDFLARE_API_TOKEN

     export WRANGLER_SEND_METRICS=false
     npm exec --offline --no -- wrangler delete \
       --config "$PWD/wrangler.jsonc" --env staging
   )
   ```

www/new の Redirect Rule は本番のホスト名にしか書けないため、staging では確認できない。
本番では「動作確認」の curl を `BASE=https://perldoc.jp` で回し、加えて
`www.perldoc.jp` が 301 でクエリを保持することを見る。staging で温めたキャッシュは
本番とは別 (外側は Worker 単位のキャッシュで別 Worker、内側はキーに含まれる
`X-Forwarded-Host` を Worker が確定する) ため、本番のキャッシュは各キー初回 MISS
から始まる。

#### run.app への直アクセス

`--allow-unauthenticated` のため `<service>.run.app` は公開のままで、Worker を
経由しないアクセスにはキャッシュもレートリミットも及ばない (「構成の概要」のとおり
実質的な上限装置は max-instances)。エッジキャッシュは二層とも Worker に
属する (外側は Worker の手前、内側は Worker の `fetch()` に付く設定) ため、
この経路では diff を含む全パスが毎回オリジンで計算される。

`X-Forwarded-Host` を信頼する構成なので、直アクセスでは `Location` のホストを
任意の値にできる。Cloudflare のキャッシュには入らない経路なのでキャッシュ汚染には
繋がらず、攻撃者が自分自身をリダイレクトさせられるだけ。塞ぐなら Worker が共有
シークレットのヘッダを付け、アプリ側でそれを条件にする。ヘッダの無いリクエストで
`ReverseProxy` を無効にするだけなら `enable_if` で足り (「構成の概要」)、一致しない
リクエストを 403 にすれば、直アクセスで diff などのアプリ処理を走らせることも
できなくなる (リクエストが Cloud Run に届くこと自体は変わらない)。いずれも下記の
LB + ingress 制限より安い。

この直アクセス経路は、構成の単純さとコストを優先して受容している残存リスクである
(完全に塞ぐには LB + ingress 制限が必要)。補助として、Cloud Run の URL と
その構成要素 (project number / ID) は §7 の分類で secret に置き、偶発的な
発見と無差別探索の可能性を下げる。これは認証ではないため、URL が第三者に
知られた時点で効果を失う。知られた後に取れる手は、サービス名や project を
変えて URL を変えるか、Worker とオリジンの間に実際の認証 (共有シークレット
ヘッダ) を足すこと。

#### workers.dev と Preview URLs

`workers_dev` と `preview_urls` は既定で有効なため、明示しないと本番 Worker は
`perldoc-jp.<subdomain>.workers.dev` と、version ごとの公開 Preview URL という
入口も持つ。どちらも perldoc.jp ゾーンの Cache / Redirect / Rate Limiting を
通らないため、wrangler.jsonc のトップレベルで両方を false にして、公開入口を
Custom Domain (perldoc.jp / staging.perldoc.jp) だけにしている。

#### Workers の枠と、Worker を挟まない構成

Workers Free は 10 万リクエスト/日。外側 (Workers Cache) の HIT で Worker が
起動しないリクエストも 1 件として数えるため、エッジキャッシュ (上の
「エッジキャッシュ」節) はこの枠の消費を減らさない (HIT では CPU 時間が課金
されないだけで、追加課金も無い)。減るのは Worker の実行回数・CPU 消費と、
Cloud Run 側のリクエスト数・CPU 消費。超える場合は Workers Paid (月 $5, 1000 万
リクエスト込み、超過 100 万あたり $0.30)。

Worker を挟まない構成にする場合の選択肢:

- Origin Rules の Host header override で run.app を直接オリジンにする。DNS だけでは
  `Host: perldoc.jp` が run.app に届いて 404 になるため書き換えが必須で、この機能は
  Enterprise 限定 (SNI override も同様)
- Cloud Run を Global External Application Load Balancer の背後に置く。自前証明書
  (Cloudflare Origin CA) が使えて Google が推奨する構成でもあるが、転送ルールだけで
  概算 月 $18〜25 かかり、min-instances=0 のコスト方針とは釣り合わない

### 11. 本番イメージのビルド (GitHub Actions)

`.github/workflows/deploy.yml` の deploy ジョブが、ビルド・smoke test・デプロイを
1 つのジョブで行う。公開リポジトリの標準 GitHub-hosted runner は実行時間が
課金されないため、ビルドそのものに費用はかからない。

避けるのは Artifact Registry からの取得である。Artifact Registry から
GitHub-hosted runner へレイヤやビルドキャッシュを引くと、そのたびにインターネットへ
出る data transfer out として課金される。このため次のように分けてある。

| 用途 | 置き場所 |
|---|---|
| ビルドキャッシュ | Actions Cache (`type=gha`, `mode=max`) |
| 完成イメージ | 1 回のビルドから GHCR と Artifact Registry の両方へ push |
| smoke test の検査対象 | GHCR から pull したイメージ |
| Cloud Run のデプロイ元 | Artifact Registry のイメージ (digest 指定) |

Artifact Registry に対して GitHub Actions が行うのは push と、digest 照合のための
メタデータ照会だけになる。レイヤを引くのは同一リージョンの Cloud Run であり、
同一ロケーション内の転送は無料である。

ビルドを別の workflow ファイルへ分けることはできない。§5 の WIF
attribute-condition が `assertion.workflow_ref` を `deploy.yml` に固定しているため、
別のファイルからは Artifact Registry への push の認証が取れない。同じファイル内での
ジョブ分割は自由だが、1 回のビルドで 2 つのレジストリへ push する以上、GHCR と GCP の
資格情報は同じジョブに揃っている必要がある。

`data/years.pl` は前段の years ジョブが `script/update-years.pl` で再導出して master へ
コミットし、その commit をソースにしてビルドする。イメージはコミットされている現物を
読むので、ビルドの成果物を GitHub へ取り出す経路は要らない。

#### 11-1. 同一イメージであることの確かめ方

`docker buildx build` にタグを 2 つ渡した 1 回のビルドなので、両レジストリに入るのは
バイト列として同じ manifest であり、digest も一致する (ローカルレジストリ 2 台で
実測済み)。deploy ジョブはそれを前提に置かず、`docker/build-push-action` が返した
digest を、両レジストリのタグが実際に指している digest と突き合わせる。

引くのは `docker buildx imagetools inspect --format '{{.Manifest.Digest}}'` による
manifest 1 個ずつ (数 KB) で、レイヤは落とさない。Artifact Registry 側も
`gcloud artifacts docker images describe` ではなく同じコマンドを使う。gcloud でも
digest は取れるが (どちらも同じ値を返すことは確認済み)、タグ参照の可否と出力
フィールド名という前提が増えるので、GHCR 側と同じ経路に揃えてある。

smoke test に渡す参照も、Cloud Run へ渡す `--image` も、タグではなく digest で書く。
これにより「smoke test で検査したもの」と「デプロイしたもの」が同じであることの根拠が、
タグ名の一致ではなく digest そのものになる。

provenance と sbom の attestation は明示的に切ってある。理由は digest ではなく
公開範囲にある。タグを 2 つ渡したビルドで `--provenance=mode=max` を有効にすると、
provenance の `subject` は両方のイメージ参照を並べた 1 つの配列になり、その
attestation がそのまま両レジストリへ push される (ローカルレジストリ 2 台で実測):

```json
"subject": [
  { "name": "pkg:docker/reg1%3A5000/probe@t2?platform=linux%2Famd64", "digest": {...} },
  { "name": "pkg:docker/reg2%3A5000/probe@t2?platform=linux%2Famd64", "digest": {...} }
]
```

つまり公開している GHCR 側の attestation に Artifact Registry の参照が載る。
project ID は §7 の分類で secret として扱っているので、これは避ける。
なお同じ実測で、attestation を有効にしても両レジストリの digest は一致した
(宛先ごとに別の attestation が作られるわけではない)。上の同一性は attestation の
有無では崩れない。

attestation は Cloud Run の要件でもない。`docker/build-push-action` が公開
リポジトリで既定的に付けていたものを踏襲していただけなので、切っても失うものは
無い。切った結果、push されるのは単一プラットフォームの素の manifest
(`application/vnd.oci.image.manifest.v1+json`) になる。有効なときは
linux/amd64 の manifest と `unknown/unknown` の attestation manifest を含む
image index になり、Cloud Run はどちらの形も受け付ける。

#### 11-2. GHCR のパッケージ

- 名前: `ghcr.io/perldoc-jp/perldoc.jp/app` (deploy.yml は `github.repository` から
  組み立てる)
- 公開範囲: public
- 保持: 自動削除しない

public にしているのは配布のためである。この構成に関わっていない利用者が、
ビルド済みのイメージをそのまま手元で起動できるようにする。run ごとのタグを
全世代残して自動削除を入れないのも同じ理由による。

費用は公開範囲を決める理由にならない。GitHub Packages には plan ごとの storage と
データ転送の枠があるが、Container registry (ghcr.io) はその例外で、イメージの
storage と帯域は公開範囲によらず現在無料とされている。private にしても枠は
消費しない。この扱いが変わる場合は 1 か月以上前に告知されるとされているので、
告知があったときに保持方針と公開範囲を見直す。

イメージの中身は公開データだけで構成されている。公開範囲を public にしてよいのは、
上の 11-1 のとおり attestation を切ってあり、push される manifest とレイヤのどこにも
GCP の識別子が入らないからである。イメージに付けるラベルも
`org.opencontainers.image.source` の 1 つだけで、値はこのリポジトリの URL になる。
`DOCKER_BUILD_RECORD_UPLOAD` と `DOCKER_BUILD_SUMMARY` を無効にしているのも同じ理由で、
build record と job summary には Artifact Registry のタグを含む build inputs が
そのまま入る。

smoke test とデプロイまで通った digest には `latest` を付ける。run ごとのタグ名を
知らなくても `docker pull ghcr.io/perldoc-jp/perldoc.jp/app` で引けるようにするための
入口である。付け替えに使う `docker buildx imagetools create` は、単一の manifest を渡しても
それを指す image index を新しく作る (実測済み)。`:latest` 自身の digest は run ごとの
タグのそれとは一致しない。11-1 の同一性の根拠に使うのは run ごとのタグのほうで、
`latest` はそこに含めない。

#### 11-3. ビルドキャッシュ

`type=gha` を `mode=max` で使う。`mode=max` にするのは、`databuild` (pod2html と
VACUUM) と `test` (prove) という高価な中間ステージを再利用するためで、`mode=min` では
`runtime` の最終レイヤしか残らない。

scope は 3 つに分かれる。

| scope | 書くジョブ | 読むジョブ |
|---|---|---|
| (既定) | test.yml の test (master への push のみ) | test.yml の test |
| `runtime` | deploy.yml の deploy | deploy.yml の deploy、test.yml の runtime-test |
| `runtime-pr` | test.yml の runtime-test | test.yml の runtime-test |

`app` ターゲットと `runtime` ターゲットで scope を分けているのは、`mode=max` の
書き込みが互いのレイヤを追い出さないようにするためである。

デフォルトブランチのキャッシュは fork を含む全 PR から読めるので、PR の
`runtime-test` は master が温めた `runtime` を読める。一方、PR が書けるのは
`runtime-pr` だけで、しかも Actions Cache は PR 単位に隔離されている。deploy ジョブが
読むのは `runtime` だけなので、PR の内容が本番ビルドの入力に混ざることはない。
fork PR に GCP の資格情報を渡す必要も無い。

キャッシュが無い状態でもビルドは通る。Actions Cache は 7 日間使われないと削除され、
リポジトリあたり 10 GiB の上限でも古いものから削除されるため、キャッシュの存在を
前提にはできない。`RUN --mount=type=cache` で持っている apt と cpm の中身は、
そもそもこの外部キャッシュには含まれない (同一マシンでの再ビルドにだけ使われる)。

キャッシュヒットは検査を飛ばさない。`prove` は Dockerfile の `test` ステージの
レイヤなので、入力が変わらなければキャッシュから出てきて再実行されない。ただし
このレイヤのキャッシュキーは親チェーン全体 (`t` / `tmpl` / `static` /
`app.psgi` の COPY と、その下の `databuild` チェーン全体、つまり translation の
commit・`lib`・`script`・`config`・`sql`・`data`) を含む。`prove` の入力が
1 つでも変われば無効化されて走り直すので、`runtime` の
`COPY --from=test /tests-passed` は「この入力に対して prove が通った」ことを
指し続ける。

smoke test のほうは Docker のレイヤではなく workflow のステップなので、
キャッシュの状態によらず毎回走る。全レイヤがキャッシュに当たったビルドでも
buildx はイメージを export して push するため、検査対象は常に存在する。

**キャッシュなしで通ることの確かめ方**

本番の run では確かめられない。`scope=runtime` のキャッシュは読まれるたびに
保持が延びるので、「キャッシュが無い run」を待つことができない。使い捨てのブランチで、
まだ存在しない scope を指してビルドする:

1. ブランチを切り、test.yml の runtime-test の `cache-from` と `cache-to` を
   `type=gha,scope=coldcheck-<日付>` のような未使用の scope 1 つに書き換える
2. push して PR を作り、runtime-test の所要時間と、`CACHED` が出ないことを見る
3. 確認できたらブランチごと捨てる

`--no-cache` は使わない。確かめたいのは「キャッシュを無視したビルド」ではなく
「読めるキャッシュが無い状態のビルド」である。gha キャッシュの import は scope ごとの
index を引くところから始まるので、未使用の scope を指せば import は起きない。
`RUN --mount=type=cache` が持つ apt と cpm も、新しいランナーでは空から始まる。

この手順が確かめるのは runtime ターゲットのビルドまでで、2 つのレジストリへの push と
digest 照合は含まない (test.yml は `load: true` でローカルに取り込むだけ)。

10 GiB はリポジトリ全体で共用する。`runtime` scope の `mode=max` は中間ステージの
レイヤまで抱えるので、PR ごとの `runtime-pr` と合わせると相応の量になる。上限に
達したときの削除は least recently used で、対象はこのリポジトリのキャッシュ全体
なので、years ジョブの `perl-deps-*` や worker-test の npm キャッシュも巻き込まれる。
使用量は次で確認する:

```sh
gh api repos/perldoc-jp/perldoc.jp/actions/cache/usage
gh cache list --repo perldoc-jp/perldoc.jp --sort size_in_bytes --order desc --limit 20
```

#### 11-4. 一度きりの操作

リポジトリのコードだけでは完結しない操作。

**初回の deploy が成功した後に**、GHCR のパッケージを public にする。
`GITHUB_TOKEN` が作るパッケージの既定は private なので、初回 push でできたものを
Packages の設定から切り替える。初回の run 自体はこの切り替えの前に完走する
(deploy ジョブは `GITHUB_TOKEN` で login していて、private のままでも pull できる)。

GHCR への push のために GitHub 側へ足す secret や variable は無い。組み込みの
`GITHUB_TOKEN` と、deploy ジョブの `packages: write` で足りる (§7)。

**初回の run で見ること:**

- 所要時間。deploy ジョブの `timeout-minutes` (60) に収まること
- `Verify the pushed digests` と `Smoke test image` が通ること
- `scope=runtime` を書いた後の Actions Cache の使用量 (11-3 のコマンド)。
  10 GiB の上限に対する余裕を数字で押さえておく

## ビルドまわりで課金対象になり得るもの

イメージのビルドと配布で課金対象になり得るもの。金額は 2026-09 時点の
公式 pricing を参照した値で、実際に請求される単価は最新のページで確認すること。

| 項目 | 単価 | 見込み |
|---|---|---|
| GitHub Actions の実行時間 | 公開リポジトリの標準 GitHub-hosted runner は無料 | イメージのビルド (§11) はここに入るが、課金されない |
| GitHub Actions Cache | 無料。リポジトリあたり 10 GiB の上限があり、超えると least recently used から削除される。7 日間使われないキャッシュも削除される | `runtime` / `runtime-pr` scope の `mode=max` が中間ステージのレイヤまで抱える。上限の削除はリポジトリ全体を対象にするので、使用量は 11-3 のコマンドで見ておく |
| GitHub Packages (GHCR) | Container registry のイメージ storage と帯域は、公開範囲によらず現在無料とされている。plan ごとの storage・データ転送の枠が効くのは、この例外に入らない package 形式のほう。扱いが変わる場合は 1 か月以上前に告知されるとされている | 全世代を残しても課金対象にならない。告知があった場合に保持方針と公開範囲を見直す (11-2) |
| Artifact Registry storage | 0〜0.5 GiB-month が $0.00、以降 $0.10/GiB-month (billing account 単位) | §2 の cleanup policy で、30 日以内の世代と最新 5 世代に抑える |
| Artifact Registry ↔ Cloud Run (同一ロケーション) | $0.00 (Free)。"Data moves within the same location" に該当する | デプロイ時のレイヤ取得がここに入る |
| Artifact Registry → インターネット (Premium Tier data transfer out) | 宛先別の階梯。North America 宛: 0〜1 GiB 無料 / 1〜1,024 GiB $0.12 / 1,024〜10,240 GiB $0.11 / 10,240 GiB 超 $0.08。Europe 宛と Asia 宛 (Korea・Indonesia を除く): 0〜1 GiB 無料 / $0.12 / $0.11 / $0.085。Australia・Indonesia・Korea・South America・Saudi Arabia 宛: $0.19 / $0.18 / $0.15。Middle East (Saudi Arabia を除く)・Africa 宛: 0〜1 GiB 無料 / $0.15 / $0.13 / $0.11。China 宛 (香港を除く): $0.23 / $0.22 / $0.20。data transfer in は無料 | この構成を避けるために §11 がある。GitHub Actions が Artifact Registry へ行うのは push (data transfer in は無料) と digest 照合のメタデータ照会だけで、レイヤは引かない。したがってここに入るのは、手元や第三者が直接 pull した分に限られる。料金表は転送元リージョンで値が変わる (ページにセレクタがある) ため、`asia-northeast1` を選んだ実際の値で確認すること |
| Cloud Logging | $0.50/GiB、50 GiB/project/month が無料。`_Default` バケットの既定保持期間 (30 日) には保持料金がかからない | Cloud Run のリクエストログとアプリケーションログの分。無料枠に収まる想定 |
| Artifact Analysis (脆弱性スキャン) | $0.26/scan。Container Scanning API を有効化したときにだけ課金が始まる。digest 単位で初回 push のみ課金され、タグの付け替えは無課金 | §1 で同 API を有効化していないため発生しない |
## `static/docs.json` の外部利用者

`static/docs.json` は Chrome 拡張と Firefox アドオンが参照している。
パスと JSON 構造 (`{パッケージ名: パス}`) を変えないこと。

- <https://chrome.google.com/webstore/detail/iedgkpbokcjamkpoglfbefmdmclkljhc>
- <https://addons.mozilla.org/ja/firefox/addon/perldocjp-firefox-addon/>

デプロイ後に古い docs.json が残る時間は、ブラウザーでは app.psgi が付ける
`Cache-Control` (2 時間) で決まる。エッジでは、平常時はデプロイ後の purge から
最大 1 時間 (外側の Workers Cache の TTL。§10)。
障害時の stale 配信はこの上限に含めない (§10 の「TTL を決める場所」)。

## 運用

- **翻訳の反映**: translation への push → 自動デプロイ (数分)。手動で回す場合は
  Actions の Deploy workflow を workflow_dispatch で実行
- **schedule の自動無効化に注意**: public リポジトリの scheduled workflow は、
  リポジトリに 60 日間アクティビティが無いと GitHub により自動で無効化される。
  perldoc.jp 本体はコミット頻度が低く、translation の更新 (workflow_dispatch)
  はこの判定のアクティビティにならないため、「日次保険」だけが黙って止まる
  ことがある (years ジョブの自動コミットはアクティビティになるため、
  translation の更新が続いている限りは起きにくい)。Actions タブの Deploy workflow に無効化の告知が出ていたら
  re-enable すること (workflow_dispatch 起動は無効化の
  対象外なので、translation 起点の反映は止まらない)
- **翻訳者の帰属がおかしいとき (並行編集の調べ方)**: `commit_events` は
  git log の出力順の初出をその path の最新イベントとして扱う。`--date-order` に
  より祖先が子より先に出ることはないので、時計の巻き戻ったコミットは日時の
  逆転として検出されて止まる。ただし同じ path を 2 つのブランチで並行して
  編集した場合、どちらを最新とするかは日時に依るため、merge の解決内容とは
  食い違いうる。疑わしいときは両親の変更が交差した merge を探す:
  ```sh
  cd assets/translation
  git log --merges --format='%H' | while read m; do
    p1=$(git rev-parse "$m^1"); p2=$(git rev-parse "$m^2")
    if b=$(git merge-base "$p1" "$p2" 2>/dev/null); then
      a=$(git -c core.quotepath=false diff --no-renames --name-only "$b" "$p1")
      c=$(git -c core.quotepath=false diff --no-renames --name-only "$b" "$p2")
    else
      # 共通の祖先が無い merge (2023 年の subtree 取り込み 3 件) は両親の
      # ツリーそのものを突き合わせる
      a=$(git -c core.quotepath=false ls-tree -r --name-only "$p1")
      c=$(git -c core.quotepath=false ls-tree -r --name-only "$p2")
    fi
    common=$(comm -12 <(echo "$a" | sort) <(echo "$c" | sort) | grep -E '\.(pod|html|md)$')
    [ -n "$common" ] && echo "$m: $common"
  done
  ```
- **ロールバック**: `gcloud run services update-traffic perldoc-jp \
  --project <PROJECT_ID> --region asia-northeast1 --to-revisions <REVISION>=100`。
  戻し先のリビジョンが指す digest が cleanup policy (§2) で Artifact Registry から
  消えている場合は、先に GHCR から同じ digest を push し直す。
  `docker buildx imagetools create` は単一の manifest を渡すと既定ではそれを指す
  image index を新しく作り、digest が変わる (11-2)。`--prefer-index=false` を付けて
  manifest をそのまま複製する:
  ```sh
  IMAGE=asia-northeast1-docker.pkg.dev/<PROJECT_ID>/perldoc-jp/app
  DIGEST=sha256:...  # gcloud run revisions describe <REVISION> の image から
  TAG=...            # GHCR のタグ一覧で DIGEST を指している run ごとのタグ
  gcloud auth configure-docker asia-northeast1-docker.pkg.dev --quiet
  docker buildx imagetools create --prefer-index=false \
    --tag "$IMAGE:$TAG" "ghcr.io/perldoc-jp/perldoc.jp/app@$DIGEST"
  # DIGEST と同じ値が出ること
  docker buildx imagetools inspect --format '{{.Manifest.Digest}}' "$IMAGE:$TAG"
  ```
  戻す前に、push し直した version の作成日時を確かめる。30 日より古い日時のままなら、
  次の cleanup で再び消える:
  ```sh
  gcloud artifacts versions describe "$DIGEST" --project <PROJECT_ID> \
    --location asia-northeast1 --repository perldoc-jp --package app \
    --format='value(createTime)'
  ```
  ロールバックは deploy.yml を通らないので、purge が走らない。内側のキャッシュには
  戻す前のリビジョンの応答が最大 24 時間残るため、トラフィックを戻した後に
  手で purge する (次の項)。
- **エッジキャッシュを手で purge する**: deploy.yml の purge ジョブと同じ
  `worker/scripts/purge-cache.sh` を使う。ロールバックの後と、purge ジョブが
  失敗して再実行もできないときに要る。消えるのは内側 (fetch の cf 設定) だけで、
  外側の Workers Cache は最大 1 時間残る。外側もすぐに消す必要があるなら、
  Worker を再デプロイして version を変える (§10)。token は §7 の
  `CLOUDFLARE_CACHE_PURGE_TOKEN` と同じ権限のものを使う。実値をコマンドラインに
  書かないのは §10 の Worker のデプロイ手順と同じ理由による:
  ```bash
  (
    set -euo pipefail
    export CLOUDFLARE_ZONE_ID=...   # 非機密 (§7)

    printf 'CLOUDFLARE_CACHE_PURGE_TOKEN: ' >&2
    IFS= read -r -s CLOUDFLARE_CACHE_PURGE_TOKEN
    printf '\n' >&2
    export CLOUDFLARE_CACHE_PURGE_TOKEN

    ./worker/scripts/purge-cache.sh
  )
  ```
  Actions から行う場合は、失敗した run の purge ジョブを Re-run failed jobs で
  再実行するか、Deploy workflow を workflow_dispatch で実行する (digest が
  同じならデプロイは飛ばされ、purge だけが走る)。
- **ログ**: Cloud Console の Cloud Run → perldoc-jp → ログ。
  リクエストログは Cloud Run が自動で記録する。アプリケーションログ
  (Log::Minimal) は app.psgi のミドルウェアが STDERR に出したものが
  Cloud Logging に入る (リクエスト毎のアクセスログをアプリは出さない)。
  エッジキャッシュ (§10) があるため、Cloud Run のリクエストログは
  ページビューではなく「エッジの MISS」に近い値になる。ページビューを
  見たい場合は Cloudflare 側の Analytics を使う
- **本番イメージのビルド**: Deploy workflow の deploy ジョブが行う (§11)。ビルドログは
  GitHub Actions のジョブログにそのまま出る。この run をキャンセルすればビルドも
  一緒に止まるので、別のシステムに残ったビルドを回収する手順は要らない
- **ビルド済みイメージを手元で動かす**: GHCR のパッケージは public なので、
  資格情報なしで引ける。`docker run --rm -p 8080:8080 ghcr.io/perldoc-jp/perldoc.jp/app`。
  特定の run のイメージが要る場合は、パッケージのタグ一覧から
  `<ビルドした commit>-<RUN_ID>-<RUN_ATTEMPT>` を選ぶ
- **どのイメージがデプロイされているかを見る**:
  ```sh
  gcloud run services describe perldoc-jp --project <PROJECT_ID> \
    --region asia-northeast1 --format='value(spec.template.spec.containers[0].image)'
  ```
  デプロイは digest 指定で行うので、ここに出るのも digest になる。同じ digest は
  GHCR にも入っているため、その時点の本番と同じイメージを手元で起動できる
- **gcloud SDK のバージョン**: deploy.yml は `setup-gcloud` の `version` を固定して
  いる。run ごとに新しい版が降ってくると、`gcloud run deploy` の引数解釈や既定値の
  変更がそのまま本番の挙動差になるため。上げるときは §8 の手動手順をその版で
  一度通してから上げる
- **data/years.pl の自動更新 (年次作業は不要)**: `.github/workflows/deploy.yml` の
  years ジョブが、イメージをビルドする前に `script/update-years.pl` で前年+当年
  (対象年は translation の最新イベントから導出) を translation の git 履歴から
  再導出し、差分があれば master へ自動コミットする。ビルドはそのコミットを
  ソースにする (構成の概要)。
  コミットの親は `github.sha` に固定してあり、push の時点で master が進んでいれば
  その run の再導出結果は捨てて `github.sha` のままビルドする (master が進んだ
  ということは後続の run があり、書き戻しはそちらに任せる)。
  再導出されるのは前年+当年だけなので、この書き戻しが無いと、ある年の統計は
  2 年後にシードのコミット時点の内容で凍結されてしまう。
  自動コミットが止まっていた場合も、対象年の翌年中に一度
  `perl script/update-years.pl <対象年>` の結果をコミットすれば回復する。
  対象年を過去に指定すればその年以降を git 履歴からまとめて再導出できる。
  ただし**指定してよいのは 2023 年以降**。
  2022 年以前は CVS と複数の旧リポジトリを当時の別実装で観測した記録で、現在の
  git 履歴からは同じ値を再現できない (訳者名も件数の数え方も別系統)。再導出は「復元」ではなく
  別の指標への置換になるため、指定しない。
  2023 年以降は現行の規則で再生成済みなので、同じ translation commit から
  再導出した結果は `data/years.pl` と一致する (回復手順は冪等)。
  2022 年以前には古い `in` の表記 (`IO::Socket-SSL` のように `_file2name` が
  ハイフンを 1 個だけ `::` にしていた頃の値) が残るが、表示だけの差で
  件数や翻訳者ごとの集計は変わらない (同一性の判定は
  `PJP::M::YearData::_dedup_in` が両方の表記を同じものとして扱う)
- **`data/years.pl` の完全性 (ビルドの前提)**: `update-years.pl` は
  既存の `data/years.pl` のうち対象年より前だけを seed として取り込み、
  対象年以降を git 履歴から再構築する (イベントが削除だけになった年の
  ブロックは残らない)。イメージのビルド (databuild) はこのファイルを再生成せず、
  コミットされている現物をそのまま取り込む。
  2022 年以前の統計は前項のとおり現在の git 履歴から再現できないため、
  過去年を含む現物が **git 管理下にコミットされていること** が前提になる。
  ローカルビルドで `/translators` が 200 を返しても、それはページが
  描画されたことを示すだけで年次データの完全性は保証しない。
