# 依存の自動更新

Renovate が毎月 1 回動き、更新のある依存ごとに pull request を作る。
設定は [.github/renovate.json5](../.github/renovate.json5)、実行は
[.github/workflows/renovate.yml](../.github/workflows/renovate.yml)。

作られた PR は他の PR と同じく test.yml (whitespace / test / runtime-test /
worker-test) を通るので、動かない更新はマージ前に落ちる。

## 更新の条件

- **公開から 7 日以上経過した版だけを対象にする** (`minimumReleaseAge`)。
  レジストリのアカウント乗っ取りで悪意ある版が公開される型の攻撃は、削除や
  advisory の公開までが数時間〜数日で済んでいるため、待つだけで大半を踏まずに
  済む。2025〜2026 年にかけて npm (v11 の `minimumReleaseAge`)・pnpm (v11 は
  1440 分が既定)・Dependabot (`cooldown`、既定 3 日) と、パッケージマネージャ
  自身がこの待ち時間を持つようになった流れと同じ対策
- **その条件を満たす中で最も新しい版へ上げる**。7 日待ちの間に更に新しい版が
  出ても、Renovate は版ごとに独立して経過日数を見るので、結果として
  「7 日以上経過している中で最新」が選ばれる
- **7 日未満の版では PR もブランチも作らない** (`internalChecksFilter=strict`)。
  保留中の更新は Dependency Dashboard の issue に出る
- **実行は毎月 1 日 21:00 UTC (2 日 6:00 JST)**。Renovate 側に schedule は
  置かず、renovate.yml の cron だけを実行の契機にしている (両方に条件を置くと、
  片方から外れたときに黙って何も起きなくなる)

まとめ方は「minor/patch は manager ごとに 1 PR、major は個別 PR」。壊れた 1 件が
他の更新まで巻き込んで止めないようにするため。

## 何を更新するか

| 対象 | manager | 備考 |
|---|---|---|
| `worker/package.json` (+ lock file) | `npm` | msw / wrangler。lock file も Renovate が更新する |
| `.github/workflows/*.yml` の `uses:` | `github-actions` | SHA ピン留めを保ったまま、SHA と `# vX.Y.Z` コメントの両方を書き換える |
| `.github/workflows/*.yml` の `node-version:` | `github-actions` | test.yml と deploy-worker.yml が同じ版なので 1 PR にまとまる |
| `Dockerfile` の `FROM perl:...` | `dockerfile` | base と runtime の 2 箇所を必ず同じ PR で動かす |
| `renovate.yml` の `renovate-version:` | `regex` (customManagers) | Renovate 自身の版。他の依存と同じく 7 日待ちを経て上がる |

`cpanfile` は対象外にしている (理由は後述)。`docker-compose.yml` は image を
ビルドしているだけで参照していないので、そもそも更新対象が無い。

### perl イメージの開発版を除外している

perl は minor が奇数の版 (5.43, 5.45, …) が開発版で、docker-perl はこれらにも
タグを振っている。docker versioning はこの慣習を知らないため、放置すると本番の
ベースイメージを開発版へ上げる PR が立つ。`allowedVersions` で minor が偶数の
ものだけを候補にしている。

## なぜ Renovate か (Dependabot との比較)

「公開から N 日待つ」はどちらにもある。Dependabot は 2025-07 に `cooldown` が
GA になり、今は設定しなくても既定で 3 日待つ。この repo で Renovate を選んだ
のは次の理由:

- **Perl (cpanfile) の manager がある**。Dependabot に Perl の ecosystem は
  無い。ただし後述のとおり、この repo では結局 cpanfile を対象外にしている
- **`.github/workflows/` の SHA ピン留めと `# vX.Y.Z` コメントの整合を保った
  まま更新できる**
- **公開日が取れない版の扱いを選べる** (`minimumReleaseAgeBehaviour`)。
  Dependabot の cooldown にこの区別は無い

代わりに Renovate は GitHub 組み込みではないので、動かすための資格情報が要る
(次節)。Mend がホストする Renovate GitHub App を入れれば private key を持たずに
済むが、その場合は第三者の App にこのリポジトリの `Contents: write` と
`Workflows: write` を渡すことになる。サプライチェーン対策として入れる仕組みで
書き込み権限の預け先を増やしたくないので、self-hosted (GitHub Actions 上で
Renovate のコンテナを動かす) にしている。

## セットアップ (一度だけ)

### 1. 専用 GitHub App

docs/cloud-run.md §9 の translation 通知用 App と同じ考え方で、Renovate 専用の
App を perldoc-jp org に作る。

- Repository permissions (Renovate が要求する最小構成):
  - **Contents: Read and write** — ブランチの作成と push
  - **Pull requests: Read and write** — PR の作成・更新・close
  - **Issues: Read and write** — Dependency Dashboard
  - **Workflows: Read and write** — `.github/workflows/` 配下の書き換え
  - **Checks: Read and write** / **Commit statuses: Read and write** —
    既存ブランチの CI 状態の読み取りと、lock file 更新に失敗したときの
    `renovate/artifacts` ステータス
- Webhook: 無効
- インストール先: **Selected repositories で perldoc-jp/perldoc.jp の 1 つだけ**

組み込み `GITHUB_TOKEN` は使えない。`GITHUB_TOKEN` で作った PR は
`pull_request` の workflow を起動しないため、Renovate の PR に test.yml が
一切走らなくなる。

### 2. environment / secret / variable

secret を読めるのを master の renovate.yml に限るため、branch policy 付きの
environment に置く (§7 と同じ手順・同じ理由)。

```sh
gh api --method PUT repos/perldoc-jp/perldoc.jp/environments/renovate \
  -F 'deployment_branch_policy[protected_branches]=false' \
  -F 'deployment_branch_policy[custom_branch_policies]=true'
gh api --method POST \
  repos/perldoc-jp/perldoc.jp/environments/renovate/deployment-branch-policies \
  -f name=master -f type=branch

# App の private key (値の入力を求められる)
gh secret set RENOVATE_APP_PRIVATE_KEY --env renovate
# App の Client ID (公開識別子)
gh variable set RENOVATE_APP_CLIENT_ID --env renovate
```

置き終わったら `gh workflow run renovate.yml` で 1 回流して、Dependency
Dashboard の issue が立つことを確認する。

### 3. Dependabot alerts はそのままにしておく

Renovate は「毎月 1 回、7 日待って上げる」ためのもので、脆弱性の通知は速さが
要る。GitHub の Dependabot alerts / security updates はリポジトリ設定側の機能で
Renovate と併用でき、cooldown の対象外なので有効なままにしておく。

## App token が侵害されたときにできること

renovate.yml は `actions/create-github-app-token` で installation token を作り、
`permission-*` で App の権限のうち Renovate が使うものだけを載せている。token は
1 時間で失効し、ジョブ終了時に revoke される。

`Contents: write` を持つため、**この token を握られると master へ直接 push
できる**。master の ruleset (docs/cloud-run.md §7) は force push とブランチ削除を
禁じているだけで、PR を必須にしていないため。これは「write 権限を持つアカウント
の侵害に対する独立レビュー境界が現状無い」という §7 の状況と同じ穴で、Renovate
用の App はその経路を 1 つ増やすことになる。

より危険なのは private key の側で、こちらは長期の資格情報。§9 と同じく定期的に
ローテーションし (App 設定で新しい鍵を追加 → secret を差し替え → 旧鍵を削除)、
漏えい時は App 設定から鍵を即失効する。

## カバーできていない範囲

### cpanfile.snapshot (CPAN)

**この repo で最も大きい依存は Renovate では更新できない。**

`cpanfile` の版指定は 4 件 (`Pod::Simple` 3.16 / `Pod::Perldoc` 3.28 /
`SQL::Maker` 0.14 / `Text::Markdown::Discount` 0.18) しかなく、いずれも
「これ以上でないと動かない」下限であって実際に入る版ではない。実際に入る版を
決めているのは `cpanfile.snapshot` (直接・推移依存あわせて全モジュール) で、
lock file を扱う機能が cpanfile manager に無いため Renovate は触れない
(Dependabot にも Perl の ecosystem 自体が無い)。

下限だけを最新へ上げても入る版は変わらず、`Text::Markdown::Discount` のように
理由付きで選んだ下限を意味なく書き換えてしまうので、`cpanfile` manager は
`enabled: false` にしている。

CPAN 側を更新したいときは、`cpanfile.snapshot` を消して `carton install` を
回し、生成された差分を PR にする:

```sh
docker build . -t perl-app-image --target base
docker run --rm -v $(pwd):/usr/src/app perl-app-image \
  bash -c 'rm -f cpanfile.snapshot && carton install'
```

これには 7 日待ちが効かない (carton は CPAN の最新へ解決する)。自動化するなら
「新しい snapshot と古い snapshot の差分に出た配布物の公開日を MetaCPAN で
引き、7 日未満のものを旧版に固定して解決し直す」という作りが要る。既製の
ツールは無い。

なお `cpanfile` を変更する PR では update-cpanfile-snapshot.yml が
`cpanfile.snapshot` を再生成してコミットするので、`cpanfile` の下限を手で
上げた場合の snapshot 追従は自動で行われる。

### Docker イメージの公開日

Docker Hub の tag API は未認証だとページングの途中で 403 を返す
(`library/perl` はタグが 1400 以上あり、必ず途中で当たる)。そうなると Renovate
は公開日を持たない registry API (v2 tags/list) へ fallback するため、公開日が
取れない。

`minimumReleaseAgeBehaviour=timestamp-required` のままだと「7 日経過を確認
できない」= 恒久的に更新されない、という気づきにくい状態になるので、docker
datasource だけ `timestamp-optional` にしている。Dockerfile は元々
`perl:5.42-trixie` という可変タグを参照していて同じタグの中身がビルドのたびに
変わる前提なので、ここで 7 日待ちが外れても実質の露出は増えない。

完全に効かせたい場合は Docker Hub の認証情報を Renovate の `hostRules` に足す。

## 運用

- **Dependency Dashboard**: Renovate が作る issue。7 日待ちで保留中の更新、
  検出したが PR にしていない更新、エラーがここに出る。動いているかどうかは
  まずこれを見る
- **PR の CI が落ちたとき**: 更新自体が壊れているか、こちらのコードが追随して
  いない。ブランチに手でコミットすると Renovate はそれ以降そのブランチを
  上書きしなくなるので、直接直してマージしてよい。見送る場合は PR を close
  する (close した版は再提案されない)
- **一時的に止めたい**: renovate.yml の schedule を消すか、workflow を disable
  する (`gh workflow disable renovate.yml`)
- **特定の依存だけ止めたい**: renovate.json5 の `packageRules` に
  `matchPackageNames` + `enabled: false` を足す
