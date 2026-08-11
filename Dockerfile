# base: ビルドツールと Carton のみ。
# .github/workflows/update-cpanfile-snapshot.yml が --target base を使う。
FROM perl:5.42-trixie AS base

ENV DEBIAN_FRONTEND=noninteractive

# apt のダウンロード済み .deb とインデックスを BuildKit の cache mount に残す
# (既定の docker-clean はキャッシュを消すため無効化する)。cache mount は
# 同一マシンでの再ビルドにのみ効き、registry cache には乗らない
RUN rm -f /etc/apt/apt.conf.d/docker-clean && \
  echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
  --mount=type=cache,target=/var/lib/apt,sharing=locked \
  apt-get update && \
  apt-get install -y --no-install-recommends wget gcc g++ make sqlite3 git

# Carton は update-cpanfile-snapshot.yml の snapshot 再生成と、deps の
# cpm --resolver snapshot (Carton::Snapshot を require する) の両方が使う
RUN --mount=type=cache,target=/root/.perl-cpm \
  cpm install -g Carton

WORKDIR /usr/src/app

COPY cpanfile cpanfile.snapshot .

ENV PERL5LIB=/usr/src/app/local/lib/perl5
ENV PATH=/usr/src/app/local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin


# deps: CPAN 依存のインストール。cpanfile が変わったときだけ再ビルドされる。
# cpm の既定は -L local / 5 並列 / モジュールテストなし (carton install も
# Menlo に --notest を渡すので従来と同じ)。--no-default-resolvers により
# cpanfile.snapshot に無いモジュールは MetaCPAN 等へフォールバックせず失敗する。
# tarball / prebuilt / build.log は cache mount 側に置かれレイヤに残らないため、
# 失敗時の詳細は --show-build-log-on-failure で標準エラーに出す
FROM base AS deps

RUN --mount=type=cache,target=/root/.perl-cpm \
  cpm install --resolver snapshot --no-default-resolvers --show-build-log-on-failure


# app: docker-compose での開発用 (従来構成そのまま)
FROM deps AS app

ENV PLACK_ENV=docker
# コンテナの時刻表示を databuild と揃える (詳細は databuild 側のコメントを参照)
ENV TZ=Asia/Tokyo

COPY . .

RUN sqlite3 perldocjp.master.db < sql/sqlite.sql
RUN cp perldocjp.master.db perldocjp.slave.db


# databuild: translation 取得 → SQLite 構築 → 生成物作成 → DB 仕上げ
FROM deps AS databuild

ENV PLACK_ENV=build

# コンテナの時刻表示を旧 VPS (JST) と揃える。翻訳イベントの日付は
# PJP::M::Repository が自分で JST に固定するため、この ENV は生成物の内容には
# 影響しない (ログや対話的な確認のためのもの)
ENV TZ=Asia/Tokyo

# translation の取得コミットを build-arg で指定する。
# CI が HEAD の SHA を渡すことで、translation が更新されたときだけ
# このレイヤのキャッシュが無効化される。
# アプリのソースより前に置いているので、ソースだけの変更では clone が
# 再実行されない。
ARG TRANSLATION_COMMIT=master

# create_data.pl が git log を使うため、
# コミット履歴付き (blob は checkout 分のみ) で取得する
RUN git clone --filter=blob:none https://github.com/perldoc-jp/translation.git assets/translation && \
  git -C assets/translation checkout --quiet ${TRANSLATION_COMMIT}

# 生成に要るものだけを持ち込む。COPY . . にすると、データ生成が一切読まない
# ファイル (tmpl/ の 1 行、CSS、t/ のテスト) を触っただけでこのレイヤが
# 無効化され、update.pl の pod2html (翻訳 2500 ファイル) から VACUUM までが
# まるごと再実行される。しかもそれが PR (test.yml) とマージ後 (deploy.yml) で
# 2 回起きる。
# 変更頻度の低い順に重ねる。data/ (= 年次統計の seed である years.pl) は
# デプロイのたびに自動コミットされる最も揮発的な入力で、しかも update.pl は
# 読まないため、ここには置かず update.pl の後・create_data.pl の直前で重ねる
COPY sql ./sql
COPY config ./config
COPY lib ./lib
COPY script ./script

# 生成物の書き出し先。static/ の中身 (css 等) は生成に要らないので入れず、
# runtime と test が context から重ねる
RUN mkdir -p db static/rss && \
  sqlite3 db/perldocjp.master.db < sql/sqlite.sql && \
  cp db/perldocjp.master.db db/perldocjp.db

RUN SKIP_ASSETS_UPDATE=1 perl script/update.pl

# 年次統計の seed (data/years.pl)。デプロイのたびに自動コミットされるため、
# update.pl より下に置いて pod2html のレイヤキャッシュを壊さないようにする
COPY data ./data

# 対象年 (translation の最新イベントの前年) は script 側で導出する。
# 壁時計から取るとコマンド文字列が入力に依らず一定のため、年をまたいでも
# キャッシュされたレイヤが再利用され、対象年が古いまま進まない
RUN perl script/create_data.pl

# ページサイズ変更を VACUUM で反映しつつ断片化を解消し、
# ANALYZE でプランナ統計を焼き込む
RUN sqlite3 db/perldocjp.db 'PRAGMA page_size = 8192; VACUUM; ANALYZE;'

RUN rm -rf assets/translation/.git db/perldocjp.master.db


# test: 本番同等データでの全テスト実行 (デプロイゲート)。
# databuild の完成状態、つまり VACUUM/ANALYZE 済みで配信するものとバイト同一の
# DB・生成物に対して prove を実行する。テストが slave DB に書き込んでも
# このステージのレイヤに隔離され、配信物には影響しない
# (t/ に dbh_master 依存は無いので master DB 削除後の状態で通る)。
# runtime が /tests-passed を COPY して依存するため、このステージを通らずに
# runtime イメージが完成することは構造的にない。
FROM databuild AS test

# アプリを起動して叩くために要るものを足す。data/ は context から重ねない。
# context の data/years.pl は seed であり、databuild が再導出した現物を
# 上書きしてしまうため (テストは配信するものを検証する)
COPY t ./t
COPY tmpl ./tmpl
COPY static ./static
COPY app.psgi toc.txt toc-var.txt ./

RUN prove -lr t/ && touch /tests-passed


# years-export: deploy.yml の commit-years-data ジョブが、ビルドで再導出された
# data/years.pl を取り出して master へ書き戻すための export 専用ステージ。
# (databuild が git から再導出するのは前年+当年だけなので、書き戻しが無いと
# ある年の統計は 2 年後にシードのコミット時点の内容で凍結されてしまう)
FROM scratch AS years-export

COPY --from=databuild /usr/src/app/data/years.pl /years.pl


# runtime: Cloud Run 用。レイヤは変更頻度の低い順に重ね、DB を最後に置く。
FROM perl:5.42-slim-trixie AS runtime

# XML::Parser (XS) が libexpat を動的リンクしているため slim には追加が必要。
# diffutils は slim にも標準で入っているが、PJP::HTMLDiff が外部コマンドの
# diff に依存していることを明示するため宣言しておく (入っていれば no-op)
RUN apt-get update && \
  apt-get install -y --no-install-recommends libexpat1 diffutils && \
  rm -rf /var/lib/apt/lists/*

WORKDIR /usr/src/app

ENV PLACK_ENV=deployment
# 現状 runtime に localtime 依存のコードはないが、ビルド時 (databuild) と揃えておく
ENV TZ=Asia/Tokyo
ENV PERL5LIB=/usr/src/app/local/lib/perl5
ENV PATH=/usr/src/app/local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

COPY --from=deps /usr/src/app/local ./local

# 配信イメージは COPY . . (denylist) にしない。CI のワークスペースに落ちた
# ファイル (google-github-actions/auth の gha-creds-*.json 等) を .dockerignore の
# 列挙漏れひとつで拾ってしまうため、実行時に読むものだけを列挙する。
# 列挙漏れは deploy.yml の smoke test が検出する (toc.txt → /index/core など)
COPY app.psgi toc.txt toc-var.txt ./
COPY config ./config
COPY lib ./lib
COPY static ./static
COPY tmpl ./tmpl

COPY --from=databuild /usr/src/app/functions.txt ./functions.txt
COPY --from=databuild /usr/src/app/data ./data
COPY --from=databuild /usr/src/app/static/rss ./static/rss
COPY --from=databuild /usr/src/app/static/docs.json ./static/docs.json
COPY --from=databuild /usr/src/app/assets ./assets
COPY --from=databuild /usr/src/app/db/perldocjp.db ./db/perldocjp.db

# test ステージへの依存アンカー。BuildKit はターゲットに不要なステージを
# ビルドしないため、この COPY が「prove 成功なしに runtime を完成させない」
# デプロイゲートそのもの。無意味なファイルコピーに見えても消さないこと
# (実行時は /tmp に tmpfs がマウントされるため配信物への影響もない)。
COPY --from=test /tests-passed /tmp/

# exec 形式 + exec で plackup を PID 1 にし、Cloud Run が送る SIGTERM を
# 直接受けてグレースフルにシャットダウンできるようにする。
# sh -c は ${PORT} 等の環境変数展開のために挟んでいる。
CMD ["sh", "-c", "exec ./local/bin/plackup -s Starlet --port ${PORT:-8080} --max-workers ${STARLET_MAX_WORKERS:-4} -Ilib app.psgi"]
