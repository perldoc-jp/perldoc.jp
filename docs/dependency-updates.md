# 依存の自動更新

Renovate が依存の更新 pull request を作る。設定は
[.github/renovate.json5](../.github/renovate.json5)、実行は
[.github/workflows/renovate.yml](../.github/workflows/renovate.yml)。
Renovate が扱えない CPAN の依存 (`cpanfile.snapshot`) は、同じ方針で動く専用の
workflow が受け持つ (後述の「CPAN (cpanfile.snapshot)」)。

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
| `cpanfile.snapshot` | (Renovate 外) | update-cpan-deps.yml が月 1 回、同じ 7 日待ちで解決し直す |

Renovate の `cpanfile` manager は無効にしている (理由は後述)。`renovate.yml` が固定している
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
  無い。ただし後述のとおり、この repo では結局 cpanfile manager を使わず、
  CPAN は専用の workflow で更新している
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

CPAN の更新 PR を作る update-cpan-deps.yml も、同じ App と同じ environment を
使う。App と鍵を増やさずに済むため。token に載せる権限は contents /
pull-requests / workflows で、workflows は前回の PR ブランチを新しい master の上に
作り直して force push するときに要る (その間に master で変わった
`.github/workflows/` も ref の更新に含まれるため)。`gh workflow run update-cpan-deps.yml` で 1 回流して、PR が作られる
ことを確認する。

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

## CPAN (cpanfile.snapshot)

この repo で最も大きい依存 (直接・推移依存あわせて 150 前後の配布物) は
`cpanfile.snapshot` が決めている。Renovate はこれを更新できないので、
専用の workflow を 2 つ置いている。

| workflow | いつ | 何をするか |
|---|---|---|
| [update-cpan-deps.yml](../.github/workflows/update-cpan-deps.yml) | 毎月 2 日 6:00 (JST) | `cpanfile.snapshot` を 7 日待ち付きで解決し直し、差分を PR にする |
| [cpan-audit.yml](../.github/workflows/cpan-audit.yml) | 毎日 6:30 (JST) | 既知の脆弱性を調べ、結果を 1 つの issue にまとめる |

### Renovate で扱わない理由

`cpanfile` の版指定は 4 件 (`Pod::Simple` 3.16 / `Pod::Perldoc` 3.28 /
`SQL::Maker` 0.14 / `Text::Markdown::Discount` 0.18) しかなく、いずれも
「これ以上でないと動かない」下限であって実際に入る版ではない。実際に入る版を
決めているのは `cpanfile.snapshot` で、lock file を扱う機能が cpanfile manager に
無いため Renovate は触れない (Dependabot には Perl の ecosystem 自体が無い)。

下限だけを最新へ上げても入る版は変わらず、`Text::Markdown::Discount` のように
理由付きで選んだ下限を意味なく書き換えてしまうので、`cpanfile` manager は
`enabled: false` にしている。

脆弱性も Renovate の経路では検知されない。Dependabot alerts が CPAN を対象に
していないため、alert 自体が立たない。

### 通常の更新 (update-cpan-deps.yml)

[.github/scripts/resolve-cpanfile-snapshot.pl](../.github/scripts/resolve-cpanfile-snapshot.pl)
が、Renovate の `minimumReleaseAge` と同じ条件で `cpanfile.snapshot` を解決し直す。

1. 空の `local/` から `carton install` し、CPAN の最新で snapshot を作る
2. 元の snapshot に無かった配布物それぞれについて、MetaCPAN で公開日を引く
3. 公開から 7 日未満のものがあれば、7 日以上経過した中で最も新しい版を
   `requires 'Module', 0, dist => 'AUTHOR/Dist-x.y.tar.gz'` で固定して 1 に戻る。
   無ければその snapshot を採用する

固定は解決のためだけの一時 cpanfile に置き、`cpanfile` 自体は書き換えない。
`cpanfile` が変わらないので `cpanfile.target` も一致したままで、
update-cpanfile-snapshot.yml は走らない。Dockerfile の deps ステージは
`cpm install --resolver snapshot` で snapshot の版をそのまま入れるので、
固定した版が本番に入る。

固定の requires は元の cpanfile より前に置き、その配布物が提供するモジュールを
すべて並べる。carton は同じモジュールへの requires が複数あると最初のものを
使うので、後ろに置くと `cpanfile` に直接書かれたモジュールの固定が効かない。
また cpanm は `dist =>` の指定をモジュール名ごとに覚えるので、1 つだけ固定すると、
同じ配布物の別のモジュールを要求する依存 (HTML-Parser なら、`HTML::Entities` を
固定しても libwww-perl が要求する `HTML::HeadParser`) がそれを最新の配布物から
入れ直してしまう。

公開日が取れない配布物は「7 日経過した」とみなさず、解決を失敗させる
(`minimumReleaseAgeBehaviour=timestamp-required` と同じ)。次の場合も失敗する。
いずれも PR は作られず、workflow の失敗として見える。

- 7 日以上前に公開された版が 1 つも無い配布物が新たに依存に入った
- 固定した版より新しい版を、別の配布物が要求している
  (その配布物側の更新が 7 日経つのを待つ)

ジョブは 2 つに分けている。CPAN の配布物の `Makefile.PL` / `Build.PL` は任意の
コードを実行できる。しかも 7 日待ちが防ぐのは「snapshot に載ること」だけで、
解決の途中 (1 回目の `carton install`) では公開直後の版も一度インストールされ、
そのコードが動く。そこで解決する `resolve` ジョブは書き込み権限も資格情報も
持たず、成果物 (`cpanfile.snapshot` と要約) を artifact に置くだけにしている。
さらにコンテナには解決に要るファイル (`cpanfile`・`cpanfile.snapshot`・
スクリプト) だけを渡し、作業ツリーは渡さない。作業ツリーごと渡すと `.git/config`
(`core.fsmonitor` など) を書き換えられ、後続の git コマンドを通じて runner 上で
コードが動く。runner 上で動けば、master の GHA キャッシュ (deploy.yml が読む) を
汚染する手口がある。cpan-audit.yml も毎日 CPAN の最新のコードを動かすので、
同じく `cpanfile.snapshot` だけを渡している。
PR を作る `pull-request` ジョブは App token を持つが、artifact をデータとして
検査してコミットするだけで、何も実行しない。

PR のブランチは `cpan-deps/update` で固定し、毎月 force push で作り直す。
ただし、そのブランチに workflow 以外のコミット (CI を通すための修正など) が
あれば上書きせずに終わる。

作られた PR は他の PR と同じく test.yml を通る。runtime-test は本番と同じ
データで全テストを回すので、動かない更新はここで落ちる。

### 脆弱性 (cpan-audit.yml)

[CPAN::Audit](https://metacpan.org/pod/CPAN::Audit) (CPAN Security Advisory
DB) で `cpanfile.snapshot` と perl 本体・同梱モジュールを調べ、既知の脆弱性が
あれば「CPAN 依存の既知の脆弱性 (cpan-audit)」という issue を作るか更新する。
無くなれば issue を閉じる。DB は毎日 CPAN から最新を入れる (advisory のデータで、
アプリの依存にはならないので 7 日待ちはかけない)。

issue の表では、配布物ごとに入り方を分けている。

- **cpanfile.snapshot**: `update-cpan-deps.yml` で直す。修正版の公開から
  7 日経っていなければ、該当する配布物だけ 7 日待ちを外して起動する
  (issue にコマンドが載る)。

  ```sh
  gh workflow run update-cpan-deps.yml -f allow_young='DBI HTTP-Tiny'
  ```

  これは Renovate の `vulnerabilityAlerts` が `minimumReleaseAge` を無視するのと
  同じ扱いで、7 日待ちを外すのは指定した配布物だけ。ほかの配布物は通常どおり
  7 日待ちで解決される
- **perl 同梱**: perl のイメージ (Dockerfile) の更新で直る。急ぐなら
  `cpanfile` に明示して CPAN の新しい版を入れる

修正版が無い advisory は issue に残り続ける。影響を確かめて、この repo が
使わない機能のものであればそのまま残してよい (issue が閉じないことで、
未対応のものがあることは見え続ける)。

脆弱性の検知から PR まで自動にはしていない。自動で PR を作るには、
cpan-audit.yml から update-cpan-deps.yml を起動する権限 (Actions: write) を
持たせる必要があり、その権限は workflow_dispatch の起動経路を増やすため。

## カバーできていない範囲

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
