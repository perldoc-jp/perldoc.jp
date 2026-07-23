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
                           - 実行時のファイル書き込みなし (完全イミュータブル)
```

- データ更新は「イメージ再ビルド + 再デプロイ」に一本化されている。VPS 時代の
  cron (10分毎の script/update.pl) に相当する処理は Dockerfile の databuild
  ステージが担う。
- 重い diff のキャッシュ (旧 heavy_diff テーブル) は廃止し、`PJP::HeavyDiffCache`
  という NOP のインターフェースに置き換えた。将来 GCS / Cloudflare R2 などへの
  保存をこのインターフェースの実装として追加できる。

## 初期セットアップ (一度だけ)

`PROJECT_ID` は作成するプロジェクト ID に読み替えること。

### 1. プロジェクトと API

```sh
gcloud projects create PROJECT_ID
gcloud config set project PROJECT_ID
gcloud services enable run.googleapis.com artifactregistry.googleapis.com \
  iamcredentials.googleapis.com sts.googleapis.com
```

### 2. Artifact Registry

```sh
gcloud artifacts repositories create perldoc-jp \
  --repository-format=docker \
  --location=asia-northeast1

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
  --location=asia-northeast1 \
  --policy-file=/tmp/cleanup-policy.json
```

### 3. デプロイ用サービスアカウントと Workload Identity Federation

GitHub Actions からキーレスで認証するための設定。

```sh
gcloud iam service-accounts create perldoc-jp-deployer

PROJECT_ID=$(gcloud config get-value project)
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')
SA=perldoc-jp-deployer@${PROJECT_ID}.iam.gserviceaccount.com

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$SA" --role=roles/run.admin
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$SA" --role=roles/artifactregistry.writer
# Cloud Run のランタイム SA (デフォルトの compute SA) として動作させる権限。
# 名前は PROJECT_NUMBER-compute@... (PROJECT_ID ではない)。
gcloud iam service-accounts add-iam-policy-binding \
  "${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
  --member="serviceAccount:$SA" --role=roles/iam.serviceAccountUser

gcloud iam workload-identity-pools create github \
  --location=global

gcloud iam workload-identity-pools providers create-oidc perldoc-jp \
  --location=global \
  --workload-identity-pool=github \
  --issuer-uri="https://token.actions.githubusercontent.com" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository" \
  --attribute-condition="assertion.repository == 'perldoc-jp/perldoc.jp'"

PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')
gcloud iam service-accounts add-iam-policy-binding "$SA" \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/github/attribute.repository/perldoc-jp/perldoc.jp" \
  --role=roles/iam.workloadIdentityUser
```

### 4. GitHub リポジトリの Variables

perldoc-jp/perldoc.jp の Settings → Secrets and variables → Actions → Variables に:

| 変数 | 値 |
|---|---|
| `GCP_PROJECT_ID` | プロジェクト ID |
| `GCP_WORKLOAD_IDENTITY_PROVIDER` | `projects/<PROJECT_NUMBER>/locations/global/workloadIdentityPools/github/providers/perldoc-jp` |
| `GCP_SERVICE_ACCOUNT` | `perldoc-jp-deployer@<PROJECT_ID>.iam.gserviceaccount.com` |

### 5. 初回デプロイ

一度 deploy.yml を回してイメージを push した後 (または手元から push した後)、
サービスの設定を確定させる:

```sh
gcloud run deploy perldoc-jp \
  --image asia-northeast1-docker.pkg.dev/${PROJECT_ID}/perldoc-jp/app:<SHA> \
  --region asia-northeast1 \
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
- deploy.yml も同じフラグ一式を毎回指定しているため、この初回コマンドと
  デプロイの実行順序に関わらずサービス設定は self-correcting になる。
  設定を変えるときは deploy.yml 側も合わせて更新すること。

### 6. translation リポジトリ側の workflow

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

### 7. カスタムドメイン (Cloudflare は既存のものを流用)

1. ドメインマッピングを作成:
   ```sh
   gcloud beta run domain-mappings create \
     --service perldoc-jp --domain perldoc.jp --region asia-northeast1
   ```
2. Cloudflare の perldoc.jp のレコードを一時的に DNS only (グレー雲) にして、
   案内された `ghs.googlehosted.com` への CNAME に変更する
3. Google 管理証明書の発行完了を待つ (`gcloud beta run domain-mappings
   describe` で確認)
4. Cloudflare の proxy (オレンジ雲) を有効に戻し、SSL/TLS モードを
   **Full (strict)** にする
5. キャッシュルール: `/static/*` は Cache Everything + 長め TTL を推奨。
   HTML はデプロイ連動で変わるため既定のままでよい

証明書の更新で問題が出る場合の代替: Cloudflare Worker で
`https://<service>.run.app` へリバースプロキシする (ドメインマッピング不要)。

## 旧 VPS の cron ジョブとの対応

VPS で `PLACK_ENV=deployment` の crontab が回していたジョブと、移行後の担当:

| 旧 cron ジョブ | 旧頻度 | 移行後 |
|---|---|---|
| `update_deployment.sh` (= `script/update.pl`) | 1日4回 (3〜6時台) | Dockerfile の databuild ステージ。translation への push で即時、加えて日次 schedule |
| `script/create_recent.pl` | 毎時 | 同上 (databuild) |
| `script/create_year_data.pl $(date +%Y)` | 毎日 4:05 | 同上 (databuild) |
| `script/create_docs.json.sh` | 6時間毎 | 同上。`script/create_docs_json.pl` に置き換え |
| `script/generate_heavy_diff.pl` | 毎時 | **廃止**。`PJP::HeavyDiffCache` が NOP のため重い diff は都度計算し、6秒超は 503 |
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
- **ロールバック**: `gcloud run services update-traffic perldoc-jp \
  --region asia-northeast1 --to-revisions <REVISION>=100`
- **ログ**: Cloud Console の Cloud Run → perldoc-jp → ログ。
  アクセスログは Plack ミドルウェアが STDERR に出すものが Cloud Logging に入る
- **年次作業**: `data/years.pl` は年をまたいだら
  `perl script/create_year_data.pl <前年>` の結果をコミットしておくと、
  ビルド時の再集計が当年分だけで済む
- **`data/years.pl` の完全性 (cutover の必須前提)**: `create_year_data.pl` は
  既存の `data/years.pl` に当年分を累積マージする方式なので、空の状態から
  ビルドすると当年分の翻訳者統計しか含まれない。過去年 (2013〜) を含む
  現物を **VPS から回収して git 管理下にコミットしてから** 本番切替すること。
  ローカルビルドで `/translators` が 200 を返しても、それはページが
  描画されたことを示すだけで年次データの完全性は保証しない。
