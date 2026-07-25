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
# make ci / make setup-data が実行する生成スクリプトを databuild と
# 同じ TZ で動かす (詳細は databuild 側のコメントを参照)
ENV TZ=Asia/Tokyo

COPY . .

RUN sqlite3 perldocjp.master.db < sql/sqlite.sql
RUN cp perldocjp.master.db perldocjp.slave.db


# databuild: translation 取得 → SQLite 構築 → 生成物作成 → DB 仕上げ
FROM deps AS databuild

ENV PLACK_ENV=build

# 生成スクリプトの時刻の扱いを旧 VPS (JST) と揃える。UTC のままだと
# - create_recent.pl の RSS が localtime に固定の +0900 表記を付けるため 9 時間ズレる
# - PJP::M::Repository の git log --since (TZ なし文字列) が UTC で解釈され、
#   JST 元旦 00:00〜09:00 のコミットが年次統計から恒久的に漏れる
# - 下の date +%Y が JST の年と食い違う時間帯が生じる
ENV TZ=Asia/Tokyo

# translation の取得コミットを build-arg で指定する。
# CI が HEAD の SHA を渡すことで、translation が更新されたときだけ
# このレイヤのキャッシュが無効化される。
# アプリのソース (COPY . .) より前に置いているので、ソースだけの変更では
# clone が再実行されない。
ARG TRANSLATION_COMMIT=master

# create_recent.pl / create_year_data.pl が git log を使うため、
# コミット履歴付き (blob は checkout 分のみ) で取得する
RUN git clone --filter=blob:none https://github.com/perldoc-jp/translation.git assets/translation && \
  git -C assets/translation checkout --quiet ${TRANSLATION_COMMIT}

COPY . .

RUN mkdir -p db && \
  sqlite3 db/perldocjp.master.db < sql/sqlite.sql && \
  cp db/perldocjp.master.db db/perldocjp.db

RUN SKIP_ASSETS_UPDATE=1 perl script/update.pl

# update.pl も内部で master→slave をコピーするが、後続の create_year_data.pl /
# create_docs_json.pl が読む slave の内容を update.pl の実装詳細に依存させない
# よう、ここで明示的にコピーしておく (空の slave を読んでも各スクリプトは
# 警告や空の生成物を出すだけでビルドは成功してしまうため)
RUN cp db/perldocjp.master.db db/perldocjp.db

RUN perl script/create_recent.pl
# 前年をターゲットにすると --since が前年 1/1 からになり、前年+当年の
# 両方を毎ビルド git から再導出する。当年ターゲットだと年をまたいだ瞬間に
# 前年分が data/years.pl のシード (最終コミット時点) で凍結され、
# シード更新から年末までの統計がサイレントに欠落する
RUN perl script/create_year_data.pl "$(($(date +%Y) - 1))"
RUN perl script/create_docs_json.pl
RUN perl script/create_index_data.pl

# create_year_data.pl が master に書いた update_time を配信用 DB に反映する
RUN cp db/perldocjp.master.db db/perldocjp.db

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
COPY . .
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
