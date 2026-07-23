# base: ビルドツールと Carton のみ。
# .github/workflows/update-cpanfile-snapshot.yml が --target base を使う。
FROM perl:5.38-bookworm AS base

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
  apt-get -y upgrade && \
  apt-get install -y wget gcc g++ make sqlite3 git

RUN cpm install -g Carton

WORKDIR /usr/src/app

COPY cpanfile cpanfile.snapshot .

ENV PERL5LIB=/usr/src/app/local/lib/perl5
ENV PATH=/usr/src/app/local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin


# deps: CPAN 依存のインストール。cpanfile が変わったときだけ再ビルドされる。
FROM base AS deps

RUN carton install --deployment


# app: docker-compose での開発用 (従来構成そのまま)
FROM deps AS app

ENV PLACK_ENV=docker

COPY . .

RUN sqlite3 perldocjp.master.db < sql/sqlite.sql
RUN cp perldocjp.master.db perldocjp.slave.db


# databuild: translation 取得 → SQLite 構築 → 生成物作成 → DB 仕上げ → テスト
FROM deps AS databuild

ENV PLACK_ENV=build

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
RUN perl script/create_recent.pl
RUN perl script/create_year_data.pl "$(date +%Y)"
RUN perl script/create_docs_json.pl

# create_year_data.pl が master に書いた update_time を配信用 DB に反映する
RUN cp db/perldocjp.master.db db/perldocjp.db

# ページサイズ変更を VACUUM で反映しつつ断片化を解消し、
# ANALYZE でプランナ統計を焼き込む
RUN sqlite3 db/perldocjp.db 'PRAGMA page_size = 8192; VACUUM; ANALYZE;'

# 本番同等データでの全テスト実行 (デプロイゲート)。
# master DB 削除前に実行するので dbh_master 依存のテストも通る。
RUN prove -lr t/

RUN rm -rf assets/translation/.git db/perldocjp.master.db


# runtime: Cloud Run 用。レイヤは変更頻度の低い順に重ね、DB を最後に置く。
FROM perl:5.38-slim-bookworm AS runtime

# XML::Parser (XS) が libexpat を動的リンクしているため slim には追加が必要
RUN apt-get update && \
  apt-get install -y --no-install-recommends libexpat1 && \
  rm -rf /var/lib/apt/lists/*

WORKDIR /usr/src/app

ENV PLACK_ENV=deployment
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

# exec 形式 + exec で plackup を PID 1 にし、Cloud Run が送る SIGTERM を
# 直接受けてグレースフルにシャットダウンできるようにする。
# sh -c は ${PORT} 等の環境変数展開のために挟んでいる。
CMD ["sh", "-c", "exec ./local/bin/plackup -s Starlet --port ${PORT:-8080} --max-workers ${STARLET_MAX_WORKERS:-4} -Ilib app.psgi"]
