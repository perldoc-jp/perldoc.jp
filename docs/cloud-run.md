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
                  WIF 認証 → その commit を固定して Cloud Build を submit
                                                         v
                Cloud Build (asia-northeast1 / cloudbuild.yaml)
                  translation取得 → SQLite構築 → データ生成
                  → テスト → Docker build → Artifact Registry push
                  → smoke test
                                                         v
                GitHub Actions / deploy ジョブ (deploy.yml)
                  Cloud Run deploy
                                                         v
[ユーザー] → Cloudflare (Worker) → Cloud Run (asia-northeast1)
                           - min-instances=0 (無アクセス時のコストほぼゼロ)
                           - イメージに read-only SQLite + translation docs を焼き込み
                           - 非 root (uid 10001) で実行。実行時の書き込みは /tmp (tmpfs) のみ
                             (Xslate キャッシュと diff 用の一時ファイル)
```

- **イメージのビルドは Cloud Build (asia-northeast1) で行う** (§11)。GitHub-hosted
  runner でビルドしていた頃は、buildcache の pull と smoke test のための image pull が
  どちらも Artifact Registry からインターネットへ出る data transfer out になっていた。
  同一ロケーション内の転送は無料なので、数百 MB〜GB 級のレイヤ転送を
  asia-northeast1 の中に閉じ込める。
  `script/smoke-test.pl` は手元に無いイメージを `docker run` の自動 pull で取りに行く
  ため、ビルドだけを移して smoke test を GitHub Actions に残す分割では転送は消えない。
  Cloud Run への deploy は GitHub Actions 側に残す (WIF の境界を維持し、Cloud Build の
  サービスアカウントに Cloud Run の権限を持たせないため)。
- **`data/years.pl` はビルドの前に更新する**。deploy.yml の years ジョブが
  `script/update-years.pl` で再導出し、差分があれば master へコミットしてから、
  その commit をソースにしてビルドする。ビルドの成果物を GitHub へ取り出す経路が
  無いので、イメージが読む years.pl とリポジトリにコミットされているものは
  常に同じ現物になる。
- データ更新は「イメージ再ビルド + 再デプロイ」に一本化されている。VPS 時代の
  cron (10分毎の script/update.pl) に相当する処理は Dockerfile の databuild
  ステージが担う。
- databuild の生成物は translation とソースの純関数として決定的に導出する。
  壁時計・ファイルの mtime・DB の行順 (インデックスの走査順で変わる) を
  結果に混ぜない。同じ入力からのビルドが同じバイト列になることで、アプリ
  だけの変更やベースイメージ更新で公開 JSON や feed の中身が動かない。
  版の選択は `PJP::M::PodFile` の `compare_version` / `get_latest` に一本化
  されていて、`static/docs.json` もこれに従う (= アプリが表示する版と常に
  一致する)。feed と年次統計の入力になる翻訳イベントは
  `PJP::M::Repository->commit_events` が git log の全走査 1 回で列挙する。
  現存ファイルごとの `git log -- <path>` を使わないのは、削除・rename された
  翻訳が見えないことに加え、translation が 2023 年に複数リポジトリを
  subtree merge で寄せ集めた経緯により、merge をまたぐ path の履歴が merge
  コミットに簡約されて翻訳者でなく merge 実行者が観測されてしまうため。
- 公開レスポンスは再デプロイまで変わらない (認証・セッション・個人化・時刻
  依存の生成が無い) ため、全パスの GET/HEAD の status 200 をエッジの二層で
  キャッシュする (§10 のエッジキャッシュ節)。外側は Workers Cache (Worker の
  手前。HIT では Worker 自体が起動しない)、内側は Worker の `fetch()` の
  `cf.cacheEverything` + `cacheTtlByStatus`。TTL は 1 時間 + 1 時間に割って
  いて、再デプロイ後に旧レスポンスが残る時間は最悪で二層の和 = 最大
  2 時間。これは従来 (単層 2 時間) から変えずに許容する。デプロイ時 purge は
  行わない。
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
  ただし `--allow-unauthenticated` のため `<service>.run.app` の URL 自体は
  公開のままであり、Cloudflare を経由しない直アクセスにはエッジキャッシュも
  レートリミットも効かない。直アクセス側の実質的な上限装置は max-instances
  (=3)。ただし
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
  cloudbuild.googleapis.com \
  iam.googleapis.com iamcredentials.googleapis.com sts.googleapis.com
```

`cloudbuild.googleapis.com` は §11 のイメージビルドが使う。

`compute.googleapis.com` は有効化しない。Cloud Run のランタイムには専用のサービス
アカウントを作る (§3) ため、Compute Engine のデフォルト SA を使わない。Cloud Build も
default pool (Google 管理側の VM) しか使わないので不要で、cloudbuild を有効化しても
巻き添えで有効にはならない (移行後の稼働状態で確認済み)。

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
は、組織ポリシーで自動付与が無効化されていない環境ではプロジェクトレベルの
`roles/editor` を持つ。いずれの場合も使わず、ロールを持たない専用 SA に固定する。

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
  指定しているため、サービス設定はデプロイの実行順序に関わらず self-correcting に
  なる。`--allow-unauthenticated` (= allUsers への run.invoker 付与) だけは
  この初回作成時のみで、以後のデプロイは IAM に触れない。デプロイ用 SA (§5) が
  IAM を書き換えられる権限を持たないためで、公開設定が消えた場合は自己修復
  されず §8 の確認で検出する。設定を変えるときは deploy.yml 側も合わせて
  更新すること。

### 5. デプロイ用サービスアカウントと Workload Identity Federation

GitHub Actions からキーレスで認証するための設定。権限はプロジェクトではなく、操作対象の
リソース (Cloud Run サービス / Artifact Registry リポジトリ / サービスアカウント) に
付与する。

イメージをビルドする Cloud Build 側は別のサービスアカウントを使う。作成と、この
デプロイ用 SA に足す分のバインディングは §11 にまとめてある。

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

# イメージの push と buildcache の読み書き。
# 本番ビルドを Cloud Build へ移した後 (§11) は、この SA が push することは
# なくなるので roles/artifactregistry.reader へ降格する。ただし削除はしない:
# gcloud run deploy はデプロイ主体にも
# artifactregistry.repositories.downloadArtifacts を要求する。
# 降格は cutover が成功してから行う (§11-3)
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

認証情報 (Cloudflare API トークン) に加え、Cloud Run の deterministic URL
(`https://<SERVICE>-<PROJECT_NUMBER>.<REGION>.run.app`) の構成要素・相関情報に
なる識別子も secret として扱う。これは認証ではなく、公開 URL の発見可能性を
下げる補助コントロール (§10 の「run.app への直アクセス」参照)。URL が第三者に
知られた時点で効果を失うことは織り込んでおく。`SERVICE=perldoc-jp` と
region は既にリポジトリ履歴で公開なので secret にしない (今から隠しても
効果がない)。

| 値 | 置き場所 |
|---|---|
| `GCP_PROJECT_ID` | environment `gcp-production` の secret |
| `GCP_PROJECT_NUMBER` | environment `gcp-production` の secret。ログに出る project number (service URL 内を含む) のマスクにも効く |
| `CLOUDFLARE_ACCOUNT_ID` | repository variable (認証情報でも URL の構成要素でもない) |
| `CLOUD_RUN_URL` | environment `cloudflare-production` の secret (§10 の Worker のオリジン) |
| `CLOUDFLARE_API_TOKEN` | environment `cloudflare-production` の secret |

environment `master-write` は secret を持たない。deploy.yml の years ジョブが
`data/years.pl` を master へ直接 push するため、その ref を master に限定する
ためだけに置く (yml 内の ref ガードは workflow_dispatch では yml ごと
差し替えられるので境界にならない。下の `CLOUDFLARE_API_TOKEN` の項と同じ理由)。

WIF provider (`projects/<PROJECT_NUMBER>/locations/global/workloadIdentityPools/github/providers/perldoc-jp`)
と SA email (`perldoc-jp-deployer@<PROJECT_ID>.iam.gserviceaccount.com`) は
deploy.yml が上記 2 つの secret から組み立てるため、個別には保存しない
(project number / ID の重複保存を避ける)。

同じ理由で、Cloud Build 移行 (§11) でも **secret も variable も増やしていない**。
builder SA email (`perldoc-jp-builder@<PROJECT_ID>.iam.gserviceaccount.com`) は
deploy.yml が `GCP_PROJECT_ID` から組み立て、`cloudbuild.yaml` 側は built-in の
`$PROJECT_ID` substitution を使う (リポジトリのファイルに project ID を書かない)。
Cloud Build が fetch するソースの URL は公開リポジトリのものなので機密ではない。

environment は workflow から参照されただけでも自動作成されるが、その場合は
branch policy の無い素通しになり、environment に secret が無ければ同名の
repository secret にフォールバックする。**必ず 3 つの environment を作って
branch policy を付けてから secret を置くこと**。`master-write` は secret を
持たないが、作らずに参照されると branch policy 無しで自動作成され、master 限定の
境界が黙って無くなる。順序も固定で、environment の作成が先
(`gh secret set --env` は既存 environment の public key を取得して
暗号化するため、environment が無ければ 404 で失敗する):

```sh
# environment の作成。custom branch policy を使う (protected_branches=true は
# 「保護ルールを持つ全ブランチを許可」の意味で、後からどこかのブランチに
# 保護ルールを足すと許可範囲も一緒に広がってしまう)
for env in gcp-production cloudflare-production master-write; do
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

# 非機密の識別子は repository variable に置く
# (deploy-worker.yml が vars.CLOUDFLARE_ACCOUNT_ID を読む)
gh variable set CLOUDFLARE_ACCOUNT_ID
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
Workers Scripts Write とされる。cutover 前の初回 staging デプロイ (= 新規の
Attach) がこのトークンで成功することを検証する。権限エラーになった場合も
**より広い権限のトークンへは逃げず**、次の順で切り分ける:

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

environment の作成と secret の登録はこの節冒頭のコマンドで行う。
deploy-worker.yml が動く前にそこまでを済ませておくこと。

WIF の attribute-condition と cloudflare-production の branch policy がどちらも
master に固定されているため、master へ merge するまで GitHub Actions からは
デプロイできない。cutover までは §8 (Cloud Run) と §10 (Worker) の手順で
手元からビルドとデプロイを行う。

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

# 確認 (master に効いているルールの一覧)
gh api repos/perldoc-jp/perldoc.jp/rules/branches/master
```

pull request 必須ルールは入れていない。deploy.yml の years ジョブが
GITHUB_TOKEN で master へ直接 push するため、PR 必須にするには push の PR 化か
bypass 用の専用 App が必要になり、単独メンテの merge も止まるため。
したがって「write 権限を持つアカウントの侵害」に対する独立レビュー境界は
現状存在しない (承認 0 の PR 必須を足してもこの境界にはならない)。
メンテナが増えたときに required approvals + CODEOWNERS へ引き上げる。
同じ ruleset を translation リポジトリの master にも適用する (GitHub App の
private key を置くため。§9)。適用直後の Deploy workflow で years ジョブの
push が成功することを確認すること。

### 8. 手動でのビルドとデプロイ

master へ merge する前の cutover はこの手順で行う。使うのは操作者自身の gcloud
認証情報で、デプロイ用 SA (§5) は経由しない。本番ビルドが Cloud Build (§11) へ
移った後もこの手順はそのまま使える (操作者の権限で手元からビルドするため、
デプロイ用 SA の権限を絞っても影響を受けない)。

Cloud Build 側の経路を手で回したい場合は、§11 の submit コマンドを
`--git-source-revision` に確かめたい commit SHA を渡して実行する。

事前に `data/years.pl` が過去年 (2002〜) を含む現物になっていることを確認する。
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

# translation の HEAD に固定する (deploy.yml / test.yml と同じ)
TRANSLATION_COMMIT=$(git ls-remote https://github.com/perldoc-jp/translation.git refs/heads/master | cut -f1)

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
- CI が作るイメージに揃えたい場合は `--provenance=mode=max` を足す。
  `cloudbuild.yaml` がこれを明示しているのは、以前 GitHub Actions で使っていた
  `docker/build-push-action` が public リポジトリの push に対して既定で
  `--attest type=provenance,mode=max` を付けており (素の buildx の既定は
  `mode=min`)、成果物の形を変えないため。Cloud Run 側の要件ではない。

本番同等の FS 制約で起動確認してからデプロイする (cloudbuild.yaml / test.yml の
smoke test と同じスクリプト)。ホスト側では Perl 5.38 以降を使用し、追加の
CPAN モジュールは必要ない:

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
- `ref` は API 上 master 以外の**既存** ref も指定できる (`-f ref=master` は
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
  正常なリクエスト 1 件ごとのログは保存件数を食うだけなので切ってある)

`CLOUD_RUN_URL` に入れる値:

```sh
gcloud run services describe perldoc-jp \
  --project="$PROJECT_ID" --region="$REGION" --format='value(status.url)'
```

手元からデプロイする場合 (cutover 時など)。wrangler は `worker/package.json` の
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

ここで `wrangler login` (OAuth) を使わないのは意図的な選択。login の既定
スコープは d1 / pages / ssl_certs / queues など Workers Scripts を大きく
超える write を含み、token が refresh token ごと平文の
`~/Library/Preferences/.wrangler/config/default.toml` に永続化される
(自動更新されるため実質無期限)。上の手順が `npm ci` をトークンより先に行う
のと同じ脅威モデル (手元の依存・マルウェアによる資格情報の奪取) に対しては、
ディスクに残らない Workers Scripts のみのトークンのほうが安全になる。
取り回しを優先して login を使う場合も
`wrangler login --scopes account:read user:read workers_scripts:write` で
絞り、作業が終わったら `wrangler logout` でセッションを破棄すること。
なお wrangler は `CLOUDFLARE_API_TOKEN` が無いと手元の OAuth セッションで
認証するため、過去に login したままの環境では意図しない資格情報でデプロイ
され得る。`wrangler whoami` で状態を確認し、残っているセッションは
logout しておく。

Worker の通常変数は `wrangler.jsonc` が、secret (ORIGIN) は `scripts/deploy.sh` が
所有する。dashboard で追加した通常変数は次回のデプロイで消える。secret は
デプロイごとに `--secrets-file` で再登録され、列挙外の既存 secret は消えない。

#### DNS

- `perldoc.jp` (apex) は Worker の **Custom Domain** として登録する。DNS レコードと
  証明書は Cloudflare が自動で作る。Workers の route にプレースホルダの
  `AAAA 100::` を置く方式は Cloudflare が非推奨としている。apex は wrangler.jsonc の
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

#### エッジキャッシュ (Workers Cache と fetch の cf 設定)

エッジのキャッシュポリシーは Worker が所有し、二層で構成する
(worker/src/index.js の `WORKERS_CACHE_TTL` / `ORIGIN_CACHE_TTL`):

- **外側: Workers Cache** (<https://developers.cloudflare.com/workers/cache/>)。
  wrangler.jsonc の `cache.enabled` で有効化する、Worker の手前のキャッシュ層。
  HIT では Worker 自体が起動しない。保持の可否と TTL は Worker が全レスポンスへ
  明示する `Cloudflare-CDN-Cache-Control` ヘッダーで制御し、GET/HEAD の 200 は
  `max-age=3600`、それ以外は `no-store` を付ける。**無指定はオプトアウトに
  ならない** — RFC 9111 のヒューリスティック (404 も 180 秒保持など) が適用
  されるため、`cache.enabled` を残したままヘッダー側だけを消してはならない。
  このヘッダーはエッジで消費されクライアントへは届かない。同一キーの同時
  MISS はデータセンター内で 1 回の Worker 起動に集約される (request
  collapsing)。キャッシュは Worker 単位かつ Worker の version 単位
  (`cross_version_cache` は既定の false) なので、Worker のデプロイごとに空から
  始まる。Cloud Run 側のデプロイでは消えない。
- **内側: `fetch()` の cf 設定**。Worker は全パスの GET/HEAD のサブリクエストに

  ```js
  cf: {
    cacheEverything: true,
    cacheTtlByStatus: { "200": 3600, "201-599": -1 },
  }
  ```

  を付けて Cloud Run へ `fetch()` する。status 200 だけが 1 時間エッジに残り、
  404 / 503 / 3xx と Worker 自身の 400 / 502 は保存されない (負数は「保存
  しない」の意味。`0` は即時失効なので使わない)。

役割分担: 外側は性能最適化 (HIT で Worker の起動と CPU を省き、同時 MISS を
束ねる)、内側はオリジン保護の backstop。外側のキーにはクライアントが自由に
変えられるヘッダー (後述) が含まれるためキー分割で MISS を強制できるが、
そうして Worker まで届いた変種も、内側では Worker が正規化した上流 URL の
キーに寄って HIT する。**外側があるからといって内側を外してはならない**。

ダッシュボードの Cache Rules に同じルールを重ねない。Workers Cache には
ゾーンの Cache Rules / Page Rules / cache level 設定がそもそも一切適用されず、
内側の `cf` 設定も Cache Rules や Page Rules より優先される (内側の優先は
compatibility date が `request_cf_overrides_cache_rules` の既定有効日
2025-04-02 以降であることが前提。wrangler.jsonc は 2026-07-25)。

TTL の所有境界:

- ブラウザー向け TTL は app.psgi が付ける `Cache-Control` が唯一の情報源
  (`/static/docs.json` と `/static/rss/` は 2 時間、それ以外の `/static/*` と
  `/favicon.ico` は 4 時間。動的 HTML には付けない)。Worker はレスポンスへ
  `Cache-Control` を足さない (`Cloudflare-CDN-Cache-Control` はエッジ専用で、
  クライアントへは届かない)。
- 外側のエッジ TTL は Worker が付ける `Cloudflare-CDN-Cache-Control` が唯一の
  情報源 (全 200 で 1 時間)。オリジンの `Cache-Control` より優先され、
  オリジンが誤って `Cloudflare-CDN-Cache-Control` を返しても Worker が
  上書きする。
- 内側のエッジ TTL は Worker の `cf` 設定が唯一の情報源 (全 200 で 1 時間)。
- 再デプロイ後の残留は最悪で外側 + 内側の和 (内側の失効直前の応答で外側が
  充填された場合)。「最大 2 時間」の予算 (構成の概要) を保つよう二層の和を
  7200 秒以内にする。片方の TTL だけを変えないこと。この予算は平常時のもの:
  Worker のエラー時は、外側が失効済みの保存応答を `Cf-Cache-Status: STALE`
  として配る。ヘッダーに `stale-if-error` を指定していないため、この stale
  配信に時間の上限は**無く**、エントリが purge・eviction されるか Worker が
  回復するまで続き得る。エラーを返すよりよいのでこれを許容する
  (`UPDATING` は `stale-while-revalidate` を明示した場合だけの状態で、
  現在のヘッダーでは発生しない)。裏返しとして、公開 URL が 200 を返し
  続けることは障害が無いことの証明にならない — 障害の検知は
  `Cf-Cache-Status: STALE` の有無と Workers Logs (proxy failed の
  console.error) で行い、古い応答を止める必要があれば purge する
  (「purge について」のとおり外側の purge API は未配線なので、緊急時は
  Worker の再デプロイによる version 分離が実質の purge になる)。
  鮮度に有限の上限が必要になったら、`stale-if-error=N` を明示して
  その値をテストで固定する。

内側のキャッシュキーは Cloudflare の既定 (サブリクエスト URL 全体と、`Origin` /
method override 系 / `X-Forwarded-Host` などの一部ヘッダー) を使う。
`cf.cacheKey` は Enterprise 限定なので使わない。この前提で:

- 一般ルートはクエリ全体がキーに残る。`/about?nonce=1` と `?nonce=2` は
  別キーになり、変種の初回はオリジンへ届く (= 現在と同じ都度計算)。アプリは
  クエリを意味に使う余地がある (`/search?q=`、tmpl/pod.tt の `c().req.uri()`
  による Source link) ため、一般ルートのクエリを推測で削ってはならない。
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
ホスト名はキーに**含まれない**が、本番と staging は別 Worker
(perldoc-jp / perldoc-jp-staging) で、キャッシュ自体が Worker 単位に
分かれているため混ざらない。diff のクエリ正規化は Worker の中の処理なので
外側キーには効かず、等価表現の変種は外側では別キーになる — それらは
Worker を起動させるだけで、正規化後の内側キーへ寄って HIT するため
Cloud Run には届かない (Worker の起動は現状の全リクエストと同じ費用)。

purge について: 内側は上流サブリクエストの run.app URL を基準に保持される
ため、perldoc.jp の URL からの単一ファイル purge は期待できない。外側には
Worker 内から呼ぶ purge API (`ctx.cache.purge`) があるが使っていない
(呼び出し経路を作ること自体が新しい入口になる)。どちらもデプロイ時 purge は
行わず、二層合計で最大 2 時間の自然失効を前提にする。Worker のデプロイは
外側を version 分離で空にするが、配信データの更新は Cloud Run 側の
デプロイなのでどちらの層も消さない。

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
優先されている、が従来どおり残る。`MISS` → `HIT` の確認手順は
「動作確認」のとおり。

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
Custom Domain にすれば、ゾーン設定 (URL 正規化・Redirect Rules・SSL/TLS) を通った
cutover 後と同じ経路で挙動を確かめられる。`workers.dev` のサブドメインはゾーンの
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

   # X-Forwarded-Host が効いていること。/chomp は /func/chomp へのリダイレクトなので、
   # ここに run.app が出たら Worker 側の不備 (/func/chomp 自体は 200 なので使えない)
   curl -sS -o /dev/null -D - "$BASE/chomp" | grep -i '^location:'

   # ブラウザー向けの Cache-Control は従来どおりオリジン由来
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
   # 出てきたら Workers Cache が効いていない構成を疑う
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
   # 外側では MISS になり得る — その場合も Worker 経由で内側の HIT に寄り、
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
   見る。エッジキャッシュ導入後の Cloud Run リクエストログは「ページビュー」
   ではなく「origin MISS」に近い値になる。

   症状から切り分ける:
   - `/chomp` の `Location` に run.app が出る → Worker が `X-Forwarded-Host` を
     付けていない
   - 200 が `DYNAMIC` のまま → wrangler.jsonc の `cache.enabled` か
     `Cloudflare-CDN-Cache-Control` がデプロイに入っていない (Development
     Mode は zoneless な外側には効かない) / (内側の層は) Development Mode が
     ON・Worker の `cf` 設定の漏れ・compatibility date
     (「エッジキャッシュ」節の切り分け順)
   - `/favicon.ico` が 404、`Cache-Control` が付かない → デプロイされているイメージが
     古い (Worker や Cloudflare の設定ではない)
4. cutover 後に片付ける (残すと staging.perldoc.jp という公開入口と Workers の
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

www/new の Redirect Rule は本番のホスト名にしか書けないため、この段階では確認できない。
cutover 時に確かめる。

#### 切り替え手順

1. Cloud Run にデプロイし、`status.url` を確認する
2. 「動作確認」のとおり staging で構成を検証する。SSL/TLS・Browser Cache TTL・
   URL 正規化はゾーン単位の設定なので、ここで確認したものが cutover 後の本番にも
   そのまま効く。エッジキャッシュは Worker のデプロイに同梱されるため、
   ゾーン側の追加操作は無い
3. 本番の Worker をデプロイする。トークンと ORIGIN の読み込みを含む実行形は
   「手元からデプロイする場合」の bash ブロックのとおり
   (`./scripts/deploy.sh production` まで一式)
4. apex の既存レコードを Worker の Custom Domain に**置き換える**。Custom Domain の
   登録は既存の apex レコードと共存できないので、ここが切り替えの瞬間になる
5. Redirect Rule を入れてから、www/new を **proxied (オレンジ雲)** に切り替える。
   グレー雲のままではリクエストが Cloudflare のエッジを通らず Redirect Rule が
   発火しない。順序を逆にすると一時的にリクエストが旧オリジンへ流れる
6. 確認: apex が 200、`/chomp` の `Location` が perldoc.jp を指すこと、
   `www.perldoc.jp` が 301 でクエリを保持すること、`/static/docs.json` と
   diff の `cf-cache-status`。「動作確認」の curl を `BASE=https://perldoc.jp` で
   回すのが早い。staging で温めたキャッシュは本番とは別 (外側は Worker 単位の
   キャッシュで別 Worker、内側はキーに含まれる `X-Forwarded-Host` を Worker が
   確定する) ため、cutover 直後の本番は各キー初回 MISS から始まる
7. staging の Worker を消す

ロールバックは Custom Domain を外して元の apex レコードに戻す。

#### run.app への直アクセス

`--allow-unauthenticated` のため `<service>.run.app` は公開のままで、Worker を
経由しないアクセスにはキャッシュもレートリミットも効かない (「構成の概要」のとおり
実質的な上限装置は max-instances)。エッジキャッシュは二層とも Worker に
属する (外側は Worker の手前、内側は Worker の `fetch()` に付く設定) ため、
この経路では diff を含む全パスが毎回オリジンで計算される。
これは受容している残存リスクの一部である。

`X-Forwarded-Host` を信頼する構成なので、直アクセスでは `Location` のホストを
任意の値にできる。Cloudflare のキャッシュには入らない経路なのでキャッシュ汚染には
繋がらず、攻撃者が自分自身をリダイレクトさせられるだけ。塞ぐなら Worker が共有
シークレットのヘッダを付け、アプリ側で一致しないリクエストを 403 にするのが最も安い。

この直アクセス経路は、構成の単純さとコストを優先して**受容している残存リスク**
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

Workers Free は 10 万リクエスト/日で、**Cloudflare のキャッシュにヒットした
リクエストも 1 件として数える**。超える場合は Workers Paid (月 $5, 1000 万
リクエスト込み、超過 100 万あたり $0.30)。エッジキャッシュ (§10 の
エッジキャッシュ節) はこの枠を減らさない — 外側 (Workers Cache) の HIT で
Worker が起動しないリクエストも 1 件として数え、追加課金も無い (HIT では
CPU 時間が課金されないだけ)。減るのは Worker の実行回数・CPU 消費と、
Cloud Run 側のリクエスト数・CPU 消費。

Worker を挟まない構成にする場合の選択肢:

- Origin Rules の Host header override で run.app を直接オリジンにする。DNS だけでは
  `Host: perldoc.jp` が run.app に届いて 404 になるため書き換えが必須で、この機能は
  **Enterprise 限定** (SNI override も同様)
- Cloud Run を Global External Application Load Balancer の背後に置く。自前証明書
  (Cloudflare Origin CA) が使えて Google が推奨する構成でもあるが、転送ルールだけで
  概算 月 $18〜25 かかり、min-instances=0 のコスト方針とは釣り合わない

### 11. Cloud Build (本番イメージのビルド)

`.github/workflows/deploy.yml` の deploy ジョブは、ビルド・テスト・smoke test を
Cloud Build (`cloudbuild.yaml`) に投げる。GitHub-hosted runner が Artifact Registry から
buildcache や runtime イメージを引くと、そのたびにインターネットへの data transfer out に
なるため、大きいレイヤ転送を asia-northeast1 の中で完結させる。

ビルドの成果物を Cloud Build から GitHub へ取り出す経路は持たない。`data/years.pl` は
その前段の years ジョブが `script/update-years.pl` で再導出して master へコミットし、
その commit をソースにしてビルドするので、イメージはコミット済みの現物を読む。

ソースは 2nd-gen の GitHub connection を使わず、**公開リポジトリの exact commit SHA を
Cloud Build 自身に fetch させる** (`gcloud builds submit <URL> --git-source-revision <SHA>`)。
`--config` に渡す `cloudbuild.yaml` だけは gcloud が手元から読んで Build を組み立てる
(ビルドの定義は呼び出し側、ビルドコンテキストは Cloud Build が fetch したもの)。
deploy.yml は years ジョブが出力した commit を `actions/checkout` してから渡すので、
どちらも同じ commit になる。
connection 方式は Cloud Build GitHub App のインストールと、Secret Manager 上に置かれる
GitHub ユーザーの OAuth トークンを常設で必要とする。このリポジトリは公開なので、
そのどれも持たずに済ませる。ローカルの checkout を送る `gcloud builds submit .` も使わない
(ソースが `gs://<PROJECT_ID>_cloudbuild` に溜まるため)。

§2 (Artifact Registry) と §5 (デプロイ用 SA) の後に、**この順で**実行する。

#### 11-1. builder サービスアカウント

preflight (11-2) は builder SA を指定して回すので、SA と最低限の IAM が先に要る。

```sh
gcloud iam service-accounts create perldoc-jp-builder \
  --project="$PROJECT_ID" --display-name='perldoc.jp Cloud Build builder'

BUILDER_SA=perldoc-jp-builder@${PROJECT_ID}.iam.gserviceaccount.com

# イメージの push と buildcache の読み書き
gcloud artifacts repositories add-iam-policy-binding perldoc-jp \
  --project="$PROJECT_ID" --location="$REGION" \
  --member="serviceAccount:$BUILDER_SA" --role=roles/artifactregistry.writer

# ビルドログの書き込み (cloudbuild.yaml は logging: CLOUD_LOGGING_ONLY)
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$BUILDER_SA" --role=roles/logging.logWriter
```

builder SA には **Cloud Run の権限を一切与えない**。デプロイは GitHub Actions 側に
残してあり (§5 の WIF が持つ「master かつ deploy.yml からのみ」という境界を維持するため)、
ビルド側にその境界を跨がせない。

Cloud Storage は使わない。ビルドの成果物を GitHub へ取り出す経路が無いので専用の
バケットは不要で、`gcloud builds submit .` を使わないためソースの staging bucket も
作られない。

#### 11-2. preflight (cutover の必須前提)

`cloudbuild.yaml` は、Cloud Build のビルドステップ実行環境について公式ドキュメントに
明記が無いことをいくつか前提にしている。**production の Cloud Build で 1 回検証してから**
cutover すること。ローカルエミュレータ (`cloud-build-local`) の実装や第三者の報告を
根拠にしない。

公式ドキュメントで確認できている (preflight の対象外):

- Cloud Build は各ステップのコンテナを `cloudbuild` という docker network に接続する
- ステップの image に Google 提供でない public / custom image を使える

preflight で確かめるのは次の 7 点:

1. ステップから `/var/run/docker.sock` が使える
2. named volume がステップ間で共有される
3. `gcr.io/cloud-builders/gcloud` の PATH 上に `docker-credential-gcloud` がある
   (Cloud SDK には同梱されており、`gcloud auth configure-docker` が `DOCKER_CONFIG`
   を尊重することも SDK のコードで確認済み。未確認なのはこの image の PATH だけ)
4. その credential helper 経由で Artifact Registry に push / pull できる
5. `docker buildx create --driver docker-container --bootstrap` が起動する
   (= ステップが `--privileged` 相当で動く)
6. `--network cloudbuild` で起動した隣のコンテナへ、別のステップから network 上の
   IP で HTTP 到達できる (`script/smoke-test.pl` が通る経路)
7. Alpine (musl) の `docker:<VERSION>-cli` から取り出した docker CLI が、glibc の
   `perl:5.42-trixie` でも実行でき、そこから docker socket を使える
   (smoke test のステップがまさにこの組み合わせ。ここが崩れると、ビルドと push が
   終わった後の一番高くつく地点で落ちる)

`docker:<VERSION>-cli` への buildx プラグインの同梱と、取り出す 2 つのバイナリが
静的リンクであることは、image の config と ELF ヘッダで確認済みなので未確認項目には
数えない。ただし `cloudbuild.yaml` と preflight のどちらにも `test -x` のガードを
残してあるので、バージョンを上げて構成が変わればそこで落ちる (落ちた場合は
`docker/buildx-bin:<VERSION>` から取る形に変える)。

```sh
cat > /tmp/cloudbuild-preflight.yaml <<'EOF'
timeout: 900s
options:
  machineType: E2_STANDARD_2
  logging: CLOUD_LOGGING_ONLY
steps:
  - id: tools
    name: 'docker:29.7.2-cli@sha256:3f4743208d2338c934d7b8bcfbe1bb54c0b2355c510ad5e0f31c0c4a54bd704e'
    entrypoint: 'sh'
    volumes:
      - name: 'ci'
        path: '/ci'
    args:
      - -ceu
      - |
        test -S /var/run/docker.sock                                   # (1)
        test -x /usr/local/libexec/docker/cli-plugins/docker-buildx    # buildx 同梱
        mkdir -p /ci/bin /ci/docker/cli-plugins
        install -m 0755 /usr/local/bin/docker /ci/bin/docker
        install -m 0755 /usr/local/libexec/docker/cli-plugins/docker-buildx \
          /ci/docker/cli-plugins/docker-buildx
        docker version

  - id: buildx
    name: 'gcr.io/cloud-builders/gcloud'
    entrypoint: 'bash'
    volumes:
      - name: 'ci'
        path: '/ci'
    env:
      - 'DOCKER_CONFIG=/ci/docker'
      - 'REGISTRY=asia-northeast1-docker.pkg.dev'
    args:
      - -ceu
      - |
        export PATH=/ci/bin:$$PATH
        test -x /ci/bin/docker                                         # (2)
        command -v docker-credential-gcloud                            # (3)
        gcloud auth configure-docker "$$REGISTRY" --quiet
        grep -q "$$REGISTRY" /ci/docker/config.json                    # (3)
        docker buildx create --name preflight --driver docker-container \
          --driver-opt image=moby/buildkit:v0.32.2@sha256:28a898719c18a33f4e8000685287fa36fd0dd9560c6440227d3a732d79bb41d8 \
          --bootstrap                                                  # (5)
        docker buildx inspect preflight

  - id: registry
    name: 'gcr.io/cloud-builders/gcloud'
    entrypoint: 'bash'
    volumes:
      - name: 'ci'
        path: '/ci'
    env:
      - 'DOCKER_CONFIG=/ci/docker'
      - 'IMAGE=asia-northeast1-docker.pkg.dev/$PROJECT_ID/perldoc-jp/app:preflight-$BUILD_ID'
    args:
      - -ceu
      - |
        export PATH=/ci/bin:$$PATH
        mkdir -p /ci/preflight
        # 到達性の検査対象。busybox の applet 構成に賭けず、この preflight が
        # すでに使っている perl イメージの上に最小の HTTP サーバを置く
        # (Alpine の busybox には httpd applet が入っていない)
        cat > /ci/preflight/server.pl <<'SERVER'
        use IO::Socket::INET;
        my $$sock = IO::Socket::INET->new(
            LocalAddr => '0.0.0.0', LocalPort => 8080, Listen => 8, ReuseAddr => 1)
            or die "listen: $$!\n";
        while (my $$conn = $$sock->accept) {
            my $$req = <$$conn>;
            print {$$conn} "HTTP/1.0 200 OK\r\nContent-Length: 12\r\n\r\npreflight-ok";
            close $$conn;
        }
        SERVER
        cat > /ci/preflight/Dockerfile <<'DOCKERFILE'
        FROM perl:5.42-trixie
        COPY server.pl /server.pl
        ENTRYPOINT []
        CMD ["perl", "/server.pl"]
        DOCKERFILE
        docker buildx build --builder preflight --platform linux/amd64 \
          --tag "$$IMAGE" --push /ci/preflight                         # (4) push
        docker pull "$$IMAGE"                                          # (4) pull
        docker run -d --name preflight-app --network cloudbuild "$$IMAGE"

  # smoke test と同じ image・同じ手段で検証する。
  # まず Alpine から持ってきた docker CLI が glibc の image で動き、socket を
  # 使えること (7)、次に隣のコンテナへ HTTP::Tiny で届くこと (6)
  - id: reachability
    name: 'perl:5.42-trixie'
    entrypoint: 'sh'
    volumes:
      - name: 'ci'
        path: '/ci'
    args:
      - -ceu
      - |
        /ci/bin/docker --version                                       # (7) 実行できるか
        /ci/bin/docker ps > /dev/null                                  # (7) socket を使えるか

        # 相手が死んでいると「到達できない」と区別が付かないので先に確かめる
        state=$$(/ci/bin/docker inspect --format '{{.State.Status}}' preflight-app)
        echo "preflight-app: $$state"
        if [ "$$state" != running ]; then
          /ci/bin/docker logs preflight-app || true
          exit 1
        fi

        # 本番の smoke test と同じく、コンテナ名ではなく network 上の IP で引く
        ip=$$(/ci/bin/docker inspect \
          --format '{{index .NetworkSettings.Networks "cloudbuild" "IPAddress"}}' \
          preflight-app)
        echo "preflight-app ip: $$ip"

        cat > /ci/reachability.pl <<'REACH'
        use HTTP::Tiny;
        my ($$ip) = @ARGV;
        $$ip =~ /\A[0-9]+(?:\.[0-9]+){3}\z/ or die "no ip on the cloudbuild network\n";
        my $$r;
        for (1 .. 10) {
          $$r = HTTP::Tiny->new(timeout => 5, proxy => undef, http_proxy => undef)
            ->get("http://$$ip:8080/");
          last if $$r->{success};
          sleep 2;
        }
        # 599 は HTTP::Tiny の内部例外で、実際の原因は content 側に入る
        die "unreachable: $$r->{status} $$r->{reason}: $$r->{content}\n"
            unless $$r->{success};
        die "unexpected body: $$r->{content}\n" unless $$r->{content} eq 'preflight-ok';
        print "reachability OK\n";
        REACH
        exec perl /ci/reachability.pl "$$ip"                            # (6)

  - id: cleanup
    name: 'gcr.io/cloud-builders/gcloud'
    entrypoint: 'bash'
    volumes:
      - name: 'ci'
        path: '/ci'
    args:
      - -ceu
      - |
        export PATH=/ci/bin:$$PATH
        docker rm -f preflight-app || true
EOF

gcloud builds submit --no-source \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --config=/tmp/cloudbuild-preflight.yaml \
  --service-account="projects/${PROJECT_ID}/serviceAccounts/${BUILDER_SA}"
```

実行するのは操作者自身の資格情報 (デプロイ用 SA はまだ使わない)。
`--service-account` を指定するので、操作者に builder SA への `iam.serviceAccounts.actAs`
が要る (Owner なら暗黙に持つ)。

preflight が push した `:preflight-<BUILD_ID>` タグは、操作者の資格情報で消しておく
(builder SA には削除権限を与えていない。放置しても §2 の cleanup policy が 30 日で回収する):

```sh
gcloud artifacts docker images delete \
  "${REGION}-docker.pkg.dev/${PROJECT_ID}/perldoc-jp/app:preflight-<BUILD_ID>" \
  --project="$PROJECT_ID" --delete-tags --quiet
```

いずれかの assertion が崩れた場合は、`cloudbuild.yaml` の該当ステップを
`gcr.io/cloud-builders/*` に寄せる、`docker run` の入れ子にする等の代替へ切り替えてから
cutover する。**preflight が全部通るまで cutover しない。**

#### 11-3. デプロイ用 SA への追加バインディングと cutover

preflight が通ってから、§5 のデプロイ用 SA に Cloud Build を submit する権限を足す。

```sh
SA=perldoc-jp-deployer@${PROJECT_ID}.iam.gserviceaccount.com

# ビルドの submit / get / list / cancel
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$SA" --role=roles/cloudbuild.builds.editor

# roles/serviceusage.serviceUsageConsumer は付けない。gcloud の IAM ドキュメントは
# builds submit の要件として挙げているが、それが要るのは source を Cloud Storage へ
# staging する経路で、git URL を source にする本構成はその分岐に入らない。
# 実際に付けない状態で submit が通ることを確認済み

# --service-account で builder SA を指定するのに要る iam.serviceAccounts.actAs
gcloud iam service-accounts add-iam-policy-binding "$BUILDER_SA" \
  --project="$PROJECT_ID" \
  --member="serviceAccount:$SA" --role=roles/iam.serviceAccountUser
```

任意: ビルドログを GitHub Actions のログに出したい場合。`cloudbuild.yaml` は
`logging: CLOUD_LOGGING_ONLY` なので、`gcloud builds log` は Cloud Logging を読む。
付与しなくても workflow は動く (ログ取得に失敗しても握りつぶし、Cloud Console の URL を
案内する)。プロジェクト全体のログ閲覧権限になるので、要否は判断すること。

```sh
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$SA" --role=roles/logging.viewer
```

ここまでで cutover し、Deploy workflow が 1 回成功することを確認する。

**cutover 時に必ず見ること:**

- `timeout: 3600s` に迫る長さのビルドでも、最後の `--push` と `--cache-to` が
  認証エラーにならないこと。credential helper は docker / buildx の起動ごとに
  呼ばれるが、buildx は 1 回の build 呼び出しの中では資格情報をキャッシュするため、
  単一の長時間ステップの内部まで更新される保証はない。問題になるようなら
  `build-runtime` を分割するか、machine type を上げてビルド時間を短くする
- 実ビルド時間を測り、`cloudbuild.yaml` の `timeout` と deploy.yml の
  `timeout-minutes` を実測に合わせて詰めること (「運用」の `gcloud builds list`)。
  移行直後の実測はレイヤに変更が無いビルドが 1 分前後、`databuild` 以降が動いた
  ビルドが 6 分程度
- 無料枠 2,500 build-minutes に対する消費ペース

**post-cutover: Artifact Registry の権限を降格する。** cutover と同時に行わないこと
(`gcloud run deploy` が失敗したとき、Cloud Build 側の配線の問題か IAM の絞りすぎかを
切り分けられなくなる)。降格後にもう 1 回デプロイが成功することまで確認する。

```sh
gcloud artifacts repositories remove-iam-policy-binding perldoc-jp \
  --project="$PROJECT_ID" --location="$REGION" \
  --member="serviceAccount:$SA" --role=roles/artifactregistry.writer

# reader は残す。gcloud run deploy はデプロイ主体にも
# artifactregistry.repositories.downloadArtifacts を要求する
gcloud artifacts repositories add-iam-policy-binding perldoc-jp \
  --project="$PROJECT_ID" --location="$REGION" \
  --member="serviceAccount:$SA" --role=roles/artifactregistry.reader
```

#### 11-4. 一度きりの操作のまとめ

リポジトリのコードだけでは完結しない操作を、実行順に並べたもの:

1. §1 の API 有効化 (`cloudbuild.googleapis.com` を含む)
2. builder SA の作成と IAM (11-1)
3. GitHub の environment `master-write` の作成 (§7)
4. preflight ビルド (11-2)
5. デプロイ用 SA への追加バインディング (11-3)
6. cutover
7. デプロイ用 SA の Artifact Registry 権限を writer → reader へ降格 (11-3)

**GitHub 側で必要なのは 3 の environment だけ** (§7 の environment 作成コマンドに
含めてある)。secret も variable も増えない。作らずに参照されると branch policy 無しで
自動作成され、years ジョブの master 限定の境界が黙って無くなるので、cutover の前に
必ず作ること。
Cloud Build の 2nd-gen connection、Cloud Build GitHub App のインストール、
Secret Manager はいずれも使わない。

## この変更で課金対象になり得るもの

イメージのビルドを Cloud Build へ移したことで増減するもの。金額は 2026-09 時点の
公式 pricing を参照した値で、実際に請求される単価は最新のページで確認すること。

| 項目 | 単価 | 見込み |
|---|---|---|
| Cloud Build build-minutes | **billing account あたり月 2,500 分が無料**。ただし脚注に "This promotional free tier is for e2-standard-2 machine types in the default pool" とあり、**promotional かつ default pool の `e2-standard-2` 限定**で、恒久ではない。超過分は $0.006/min。端数は実消費秒数で按分され、queue 待ちの時間は課金されない | 移行直後の実測では、レイヤに変更が無いビルドが 1 分前後、`databuild` 以降が動いたビルドが 6 分程度 (`build-runtime` が 5 分)。日次 schedule と translation 通知の頻度を考えても無料枠には大きな余裕がある |
| Artifact Registry storage | 0〜0.5 GiB-month が $0.00、以降 $0.10/GiB-month (billing account 単位) | 既存費用。§2 の cleanup policy のまま変わらない |
| Artifact Registry ↔ Cloud Build (同一ロケーション) | **$0.00 (Free)**。"Data moves within the same location" に該当し、Cloud Build への data transfer in も無料 | **この変更の主目的**。buildcache の pull・イメージの push・smoke test のための pull がすべてここに入る |
| Artifact Registry → インターネット (Premium Tier data transfer out) | 宛先別の階梯。North America 宛: 0〜1 GiB 無料 / 1〜1,024 GiB $0.12 / 1,024〜10,240 GiB $0.11 / 10,240 GiB 超 $0.08。Europe 宛と Asia 宛 (Korea・Indonesia を除く): 0〜1 GiB 無料 / $0.12 / $0.11 / $0.085。Australia・Indonesia・Korea・South America・Saudi Arabia 宛: $0.19 / $0.18 / $0.15。Middle East (Saudi Arabia を除く)・Africa 宛: 0〜1 GiB 無料 / $0.15 / $0.13 / $0.11。China 宛 (香港を除く): $0.23 / $0.22 / $0.20。data transfer in は無料 | **削減対象**。GitHub-hosted runner は Google のサービスではないので、runner が引くイメージ・キャッシュはここに入っていた。料金表は転送元リージョンで値が変わる (ページにセレクタがある) ため、`asia-northeast1` を選んだ実際の値で確認すること |
| Cloud Logging | $0.50/GiB、**50 GiB/project/month が無料**。`_Default` バケットの既定保持期間 (30 日) には保持料金がかからない | `logging: CLOUD_LOGGING_ONLY` にしたビルドログの分。無料枠に収まる想定 |
| Cloud Storage | — | **使わない**。ビルドの成果物を GitHub へ取り出す経路が無いので専用バケットは要らず、`gcloud builds submit .` を使わないためソースの staging bucket も作られない |
| Artifact Analysis (脆弱性スキャン) | $0.26/scan。**Container Scanning API を有効化したときにだけ**課金が始まる。digest 単位で初回 push のみ課金され、タグの付け替えは無課金 | §1 で同 API を有効化していないため、**この変更で新たに発生する費用ではない**。有効化した場合も、push 元が GitHub Actions か Cloud Build かで差は出ない |

避けている費用:

- `gcloud builds submit .` を使わないので、ソースの staging bucket
  (`gs://<PROJECT_ID>_cloudbuild`) は作られない。
- `logging: CLOUD_LOGGING_ONLY` により `defaultLogsBucketBehavior` は無視され、
  自プロジェクト内に GCS のログバケットは作られない。

## 旧 VPS の cron ジョブとの対応

VPS で `PLACK_ENV=deployment` の crontab が回していたジョブと、移行後の担当:

| 旧 cron ジョブ | 旧頻度 | 移行後 |
|---|---|---|
| `update_deployment.sh` (= `script/update.pl`) | 1日4回 (3〜6時台) | Dockerfile の databuild ステージ。translation への push で即時、加えて日次 schedule |
| `script/create_recent.pl` | 毎時 | 同上 (databuild)。`script/create_data.pl` に統合 |
| `script/create_year_data.pl $(date +%Y)` | 毎日 4:05 | `script/update-years.pl`。deploy.yml の years ジョブがイメージのビルドより前に実行し、結果を master へコミットする。ターゲットは translation の最新イベントの前年 (script 側で導出) に変更し、前年+当年を毎回 git から再導出する (年またぎの欠落を自己修復) |
| `script/create_docs.json.sh` | 6時間毎 | 同上。`script/create_data.pl` に置き換え |
| `script/generate_heavy_diff.pl` | 毎時 | **廃止**。diff 計算を GNU diff 外部コマンド化 (`PJP::HTMLDiff`) で高速化したため都度計算で足り、同じ比較の反復は Cloudflare のエッジキャッシュ (§10) が吸収する |
| `script/scrape_cpan.pl` | (コメントアウト済み) | 廃止 |

反映頻度は旧構成 (1日4回) より速くなる。translation の push を
workflow_dispatch (§9) で受けるため、翻訳がマージされてから数分で反映される。

### `static/docs.json` は外部から参照されている

`static/docs.json` は Chrome 拡張と Firefox アドオンが参照している。
移行後もパスと JSON 構造 (`{パッケージ名: パス}`) を変えないこと。

- <https://chrome.google.com/webstore/detail/iedgkpbokcjamkpoglfbefmdmclkljhc>
- <https://addons.mozilla.org/ja/firefox/addon/perldocjp-firefox-addon/>

デプロイ後に古い docs.json が残る時間は、ブラウザーは app.psgi が付ける
`Cache-Control` (2 時間) で決まる。エッジでは、平常時は外側の Workers Cache
(1 時間) と内側の `fetch()` キャッシュ (1 時間) の二層合計で最大 2 時間 (§10)。
障害時の stale 配信はこの上限に含めない (§10 の TTL の所有境界)。
旧構成の更新間隔は 6 時間毎だった。

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
  現在の履歴で交差するのは 2023 年の 1 件だけで、並行した 2 つのコミットも
  merge も同じ翻訳者、その path は翌年に rename で消えているため、
  現在の統計と feed には現れない
- **ロールバック**: `gcloud run services update-traffic perldoc-jp \
  --project <PROJECT_ID> --region asia-northeast1 --to-revisions <REVISION>=100`
- **ログ**: Cloud Console の Cloud Run → perldoc-jp → ログ。
  リクエストログは Cloud Run が自動で記録する。アプリケーションログ
  (Log::Minimal) は app.psgi のミドルウェアが STDERR に出したものが
  Cloud Logging に入る (リクエスト毎のアクセスログをアプリは出さない)。
  エッジキャッシュ (§10) の導入後、Cloud Run のリクエストログは
  ページビューではなく「エッジの MISS」に近い値になる。ページビューを
  見たい場合は Cloudflare 側の Analytics を使う
- **本番イメージのビルド**: Cloud Build (asia-northeast1) が行う (§11)。ビルドログは
  Cloud Logging に入り (`logging: CLOUD_LOGGING_ONLY`)、Deploy workflow が完了後に
  `gcloud builds log` でまとめて GitHub Actions のログへ出す。この設定では live
  streaming ができないので、進行中の様子を見たいときは Deploy workflow が submit
  直後に表示する Cloud Console の URL を開く。
  デプロイ用 SA に `roles/logging.viewer` を付けていない場合はログの取り出しに
  失敗するが、その場合も workflow はビルドの成否だけで進退を決める (§11-3)
- **ビルドを手で止める**:
  `gcloud builds cancel <BUILD_ID> --project <PROJECT_ID> --region asia-northeast1`。
  Deploy workflow 側がキャンセル・失敗した場合は workflow が自動で cancel する。
  そのとき対象を引くのに使っているのは build ID ではなく run ごとに一意な
  `_TAG` substitution で、`gcloud builds submit` が ID を返す前に中断されても
  受理済みのビルドを回収できるようにしてある。`_TAG` の先頭は `github.sha` では
  なく **実際にビルドした commit** (years ジョブが書き戻していればその commit)。
  手で探す場合も同じ引き方をする:
  ```sh
  gcloud builds list --project <PROJECT_ID> --region asia-northeast1 --ongoing \
    --filter='substitutions._TAG=<ビルドした commit>-<RUN_ID>-<RUN_ATTEMPT>' \
    --format='value(id)'
  ```
  進行中のものを全部見たいときは `--filter` を外す。放置すると、次の run のビルドと
  同時に `:buildcache` を書きに行き、last-writer-wins で以後のキャッシュヒット率が落ちる
- **gcloud SDK のバージョン**: deploy.yml は `setup-gcloud` の `version` を固定して
  いる。`cloudbuild.yaml` の解釈は client 側 (gcloud) で行われ、gcloud は知らない
  enum 値を「そのフィールドは未使用」として扱う。`options.machineType` の
  `E2_STANDARD_2` がクライアントの enum に入ったのは **572.0.0** で、571.0.0 以前には
  無い (450 / 500 / 570 で不在、572 以降で存在することを確認)。machine type 自体は
  2023 年から使えるため、値の古さからは判断できない。それ以前の版で submit すると
  `.options.machineType: unused` で submit の手前で落ちる。
  上げるときは 572.0.0 以上であること、およびその版でこの `cloudbuild.yaml` が
  解釈できることを確かめてから上げる (存在しない project に対して
  `gcloud builds submit --no-source --config cloudbuild.yaml` を実行すると、
  API 呼び出しの手前まで進むので client 側の解釈だけを試せる)
- **Docker Hub の pull 回数**: ビルド 1 回につき、ステップの image
  (`docker:<VERSION>-cli` / `moby/buildkit:<VERSION>` / `perl:5.42-trixie`) と
  Dockerfile のベース (`perl:5.42-trixie` / `perl:5.42-slim-trixie`) を Docker Hub から
  引く。Cloud Build の default pool は共有の egress IP から出るため、GitHub-hosted
  runner だった頃より匿名 pull のレート制限に当たりやすい。当たった場合は
  Artifact Registry の remote repository (Docker Hub のプロキシ) を作ってそちらを
  参照するように `cloudbuild.yaml` と `Dockerfile` を書き換える
- **無料枠の消費を見る**: Cloud Build の無料枠は billing account あたり月 2,500
  build-minutes で、default pool の `e2-standard-2` にだけ適用される promotional な枠
  (「この変更で課金対象になり得るもの」参照)。所要時間は
  `gcloud builds list --project <PROJECT_ID> --region asia-northeast1 --limit 20 --format='table(id,status,createTime,startTime,finishTime)'`
  で確認する
- **data/years.pl の自動更新 (年次作業は不要)**: `.github/workflows/deploy.yml` の
  years ジョブが、イメージをビルドする前に `script/update-years.pl` で前年+当年
  (対象年は translation の最新イベントから導出) を translation の git 履歴から
  再導出し、差分があれば master へ自動コミットする。ビルドはそのコミットを
  ソースにするので、リポジトリにある years.pl とイメージが読むものは同じ現物になる。
  コミットの親は `github.sha` に固定してあり、push の時点で master が進んでいれば
  その run の再導出結果は捨てて `github.sha` のままビルドする (master が進んだ
  ということは後続の run があり、書き戻しはそちらに任せる)。
  再導出されるのは前年+当年だけなので、この書き戻しが
  無いと、ある年の統計は 2 年後にシードのコミット時点の内容で凍結されてしまう。
  自動コミットが止まっていた場合も、対象年の翌年中に一度
  `perl script/update-years.pl <対象年>` の結果をコミットすれば回復する。
  対象年を過去に指定すればその年以降を git 履歴からまとめて再導出できる。
  ただし**指定してよいのは 2023 年以降**。
  2022 年以前は CVS 期の別実装が書いた記録で、**現在の git 履歴からは同じ値を
  再現できない** (訳者名も件数の数え方も別系統)。再導出は「復元」ではなく
  別の指標への置換になるため、指定しない。
  2023 年以降は現行の規則で再生成済みなので、同じ translation commit から
  再導出した結果は `data/years.pl` と一致する (回復手順は冪等)。
  2022 年以前には古い `in` の表記 (`IO::Socket-SSL` のように `_file2name` が
  ハイフンを 1 個だけ `::` にしていた頃の値) が残るが、表示だけの差で
  件数や翻訳者ごとの集計は変わらない (同一性の判定は
  `PJP::M::YearData::_dedup_in` が両方の表記を同じものとして扱う)
- **`data/years.pl` の完全性 (cutover の必須前提)**: `update-years.pl` は
  既存の `data/years.pl` のうち対象年より前だけを seed として取り込み、
  対象年以降を git 履歴から再構築する (イベントが削除だけになった年の
  ブロックは残らない)。イメージのビルド (databuild) はこのファイルを再生成せず、
  コミットされている現物をそのまま取り込む。
  2022 年以前の統計は CVS と複数の旧リポジトリを当時の
  システムで観測した結果の凍結で、現在の git 履歴からは再現できないため、
  過去年を含む現物が **git 管理下にコミットされていること** が前提になる。
  ローカルビルドで `/translators` が 200 を返しても、それはページが
  描画されたことを示すだけで年次データの完全性は保証しない。
