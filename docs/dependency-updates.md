# 依存の自動更新

Renovate が依存の更新 pull request を作る。設定は
[.github/renovate.json5](../.github/renovate.json5)、実行は
[.github/workflows/renovate.yml](../.github/workflows/renovate.yml)。

workflow は**日次**で Renovate を起動するが、出る PR の頻度は 2 種類に分かれる。

| | いつ PR が出るか | 7 日待ち |
|---|---|---|
| 通常の更新 | 毎月 2 日 (JST) | あり |
| 脆弱性の修正 | 検知した翌朝 (日次実行のたび) | なし |

Renovate の `schedule` は Renovate を起動する設定ではなく、起動済みの Renovate が
ブランチを作ってよい期間を絞る設定なので、日次の workflow と組み合わせて使う。
脆弱性修正の PR (`vulnerabilityAlerts`) は `schedule` や `minimumReleaseAge`、
各種 limit を無視して作られるため、日次実行がそのまま検知から PR までの間隔に
なる。

作られた PR は他の PR と同じく test.yml (whitespace / test / runtime-test /
worker-test) を通るので、動かない更新はマージ前に落ちる。

## 通常の更新の条件

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
- **ブランチを作ってよいのは毎月 2 日 (JST) だけ** (`schedule: ['* * 2 * *']` +
  `timezone: 'Asia/Tokyo'`)。期間外は既存ブランチの更新もしない
  (`updateNotScheduled: false`)

まとめ方は「minor/patch は manager ごとに 1 PR、major は個別 PR」。壊れた 1 件が
他の更新まで巻き込んで止めないようにするため。

## 何を更新するか

| 対象 | manager | 備考 |
|---|---|---|
| `worker/package.json` (+ lock file) | `npm` | msw / wrangler。lock file も Renovate が更新する |
| `.github/workflows/*.yml` の `uses:` | `github-actions` | SHA ピン留めを保ったまま、SHA と `# vX.Y.Z` コメントの両方を書き換える |
| `.github/workflows/*.yml` の `node-version:` | `github-actions` | test.yml と deploy-worker.yml が同じ版なので 1 PR にまとまる |
| `Dockerfile` の `FROM perl:...` | `dockerfile` | base と runtime の 2 箇所を必ず同じ PR で動かす |

`cpanfile` は対象外にしている (理由は後述)。`renovate.yml` が固定している
Renovate 自身の版も対象外で、手で上げる (後述)。`docker-compose.yml` は image を
ビルドしているだけで参照していないので、そもそも更新対象が無い。

### perl イメージの開発版を除外している

perl は minor が奇数の版 (5.43, 5.45, …) が開発版で、docker-perl はこれらにも
タグを振っている。docker versioning はこの慣習を知らないため、放置すると本番の
ベースイメージを開発版へ上げる PR が立つ。`allowedVersions` で minor が偶数の
ものだけを候補にしている。

### action の digest 更新は受け入れない

`uses:` の更新のうち `digest` 更新 —— バージョンタグはそのままで SHA だけを、
そのタグが今指しているコミットへ差し替えるもの —— は無効にしている。

上流でタグが付け替え (force push) されると、同じタグの指す中身が入れ替わる。
Renovate はタグの当初の公開日で経過日数を見るため、差し替え後のコミットでも
7 日待ちを即座に通過しうる。SHA ピン留めは「タグが付け替えられても中身が変わら
ない」ための措置なので、それを自動で追随させると意味が薄れる。

minor / patch / major によるバージョン変更は引き続き更新対象。

## なぜ Renovate か (Dependabot との比較)

「公開から N 日待つ」はどちらにもある。Dependabot は 2025-07 に `cooldown` が
GA になり、今は設定しなくても既定で 3 日待つ。この repo で Renovate を選んだ
のは次の理由:

- **Perl (cpanfile) の manager がある**。Dependabot に Perl の ecosystem は
  無い。ただし後述のとおり、この repo では結局 cpanfile を対象外にしている
- **`.github/workflows/` の SHA ピン留めと `# vX.Y.Z` コメントの整合を保った
  まま更新できる**。digest 更新だけを個別に無効にすることもできる
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

- Repository permissions:
  - **Contents: Read and write** — ブランチの作成と push
  - **Pull requests: Read and write** — PR の作成・更新・close
  - **Issues: Read and write** — Dependency Dashboard
  - **Workflows: Read and write** — `.github/workflows/` 配下の書き換え
  - **Checks: Read and write** / **Commit statuses: Read and write** —
    既存ブランチの CI 状態の読み取りと、lock file 更新に失敗したときの
    `renovate/artifacts` ステータス
  - **Dependabot alerts: Read-only** — 脆弱性修正 PR の入力。これが無いと
    `vulnerabilityAlerts` は何も検知しない
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

### 3. リポジトリの security 設定

脆弱性の情報源は Dependabot alerts のまま残し、PR を作るのは Renovate だけに
する。通常の更新も脆弱性の修正も、PR の作成主体を 1 つにまとめるため。

- **Dependency graph: 有効** (Dependabot alerts の前提)
- **Dependabot alerts: 有効** (Renovate が読む脆弱性情報)
- **Dependabot security updates: 無効** (Dependabot 自身には PR を作らせない)

#### 安全な切り替え順序

脆弱性 PR の作成経路が一時的に途切れないよう、この順で切り替える。

1. GitHub App に `Dependabot alerts: Read-only` を追加する
2. installation token に `permission-vulnerability-alerts: read` を追加する
   (renovate.yml。この PR で入っている)
3. Renovate を日次実行にする (renovate.yml。この PR で入っている)
4. `vulnerabilityAlerts` と通常更新の月次 `schedule` を設定する
   (renovate.json5。この PR で入っている)
5. Renovate が Dependabot alert を読んで脆弱性 PR を作れることを確認する
6. Dependabot security updates を無効化する

## Renovate 自身の版を上げる

renovate.yml の `renovate-version` は、タグではなくコンテナの digest まで
固定している。実際に走るのは action ではなく
`ghcr.io/renovatebot/renovate` のコンテナで、そこへ contents / workflows の
write を持つ App token を渡すため。タグは可変で、同じ文字列のまま中身が
変わりうる。

この 1 行だけは Renovate 自身に更新させず手で上げる。GHCR は公開日を返さない
ので 7 日待ちの判定ができず、docker datasource で自動更新させると待ち時間なしで
上がってしまうため。

```sh
# 7 日以上経過している最新のリリースを探す
curl -sS https://registry.npmjs.org/renovate | \
  jq -r '.time | to_entries[] | select(.key | test("^[0-9]")) | "\(.value) \(.key)"' | \
  sort | awk -v cut="$(date -u -d '7 days ago' +%FT%TZ)" '$1 <= cut' | tail -1

# そのバージョンのコンテナ digest を取る
VER=44.39.1
TOKEN=$(curl -sS "https://ghcr.io/token?scope=repository:renovatebot/renovate:pull&service=ghcr.io" | jq -r .token)
curl -sSI -H "Authorization: Bearer $TOKEN" \
  -H 'Accept: application/vnd.oci.image.index.v1+json' \
  "https://ghcr.io/v2/renovatebot/renovate/manifests/$VER" | grep -i '^docker-content-digest'
```

得られた値を `renovate-version: <version>@<digest>` の形で書き、コメントの
公開日も併せて更新する。実行されるイメージを決めるのは digest なので、
バージョンと digest は必ずセットで書き換えること。

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

**この repo で最も大きい依存は Renovate では更新できない。通常の更新でも、
脆弱性の修正でも同じ。**

`cpanfile` の版指定は 4 件 (`Pod::Simple` 3.16 / `Pod::Perldoc` 3.28 /
`SQL::Maker` 0.14 / `Text::Markdown::Discount` 0.18) しかなく、いずれも
「これ以上でないと動かない」下限であって実際に入る版ではない。実際に入る版を
決めているのは `cpanfile.snapshot` (直接・推移依存あわせて全モジュール) で、
lock file を扱う機能が cpanfile manager に無いため Renovate は触れない
(Dependabot にも Perl の ecosystem 自体が無い)。

下限だけを最新へ上げても入る版は変わらず、`Text::Markdown::Discount` のように
理由付きで選んだ下限を意味なく書き換えてしまうので、`cpanfile` manager は
`enabled: false` にしている。

`vulnerabilityAlerts` の経路でも CPAN はカバーされない。Dependabot alerts が
CPAN を対象にしていないため、脆弱性が出ても alert 自体が立たない。CPAN の
セキュリティ情報は別途 (CPAN Security Group の advisory など) 追う必要がある。

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
できない」= 恒久的に更新されない、という気づきにくい状態になるので、perl の
イメージだけ `timestamp-optional` にしている (docker datasource 全体には
広げていない。他のイメージを足したときに気づかないまま 7 日待ちが外れるため)。
Dockerfile は元々 `perl:5.42-trixie` という可変タグを参照していて同じタグの
中身がビルドのたびに変わる前提なので、ここで 7 日待ちが外れても実質の露出は
増えない。

完全に効かせたい場合は Docker Hub の認証情報を Renovate の `hostRules` に足す。

## 運用

- **Dependency Dashboard**: Renovate が作る issue。7 日待ちで保留中の更新、
  月次の schedule 待ちの更新、検出したが PR にしていない更新、エラーがここに
  出る。日次実行しているので、2 日以外の日でも中身は毎朝更新される。動いて
  いるかどうかはまずこれを見る
- **PR の CI が落ちたとき**: 更新自体が壊れているか、こちらのコードが追随して
  いない。ブランチに手でコミットすると Renovate はそれ以降そのブランチを
  上書きしなくなるので、直接直してマージしてよい
- **特定の更新を見送りたいとき**: PR を close するだけでは足りない。
  Renovate の `recreateWhen` は既定の `auto` でも package group を再作成対象と
  して扱うため、グループ化している npm と github-actions の minor/patch PR は
  close しても次回以降に再作成されることがある。継続的に見送るなら
  `packageRules` に `enabled: false` / `allowedVersions` / `ignoreDeps` などで
  対象と理由を設定として残す。
  `recreateWhen: 'never'` を全体に設定するとグループの中身が変わったときにも
  再作成されなくなるため、見送り対象は packageRules に明示する運用にしている
- **一時的に止めたい**: workflow を disable する
  (`gh workflow disable renovate.yml`)
