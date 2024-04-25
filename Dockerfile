FROM perl:5.38-bookworm as base

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
  apt-get -y upgrade && \
  apt-get install -y wget gcc g++ make sqlite3

RUN cpm install -g Carton

WORKDIR /usr/src/app

COPY cpanfile cpanfile.snapshot .

ENV PLACK_ENV=docker
ENV PERL5LIB=/usr/src/app/local/lib/perl5
ENV PATH=/usr/src/app/local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin


FROM base as app

RUN carton install --deployment
COPY . .

RUN sqlite3 perldocjp.master.db < sql/sqlite.sql
RUN cp perldocjp.master.db perldocjp.slave.db

# 翻訳データの更新
RUN perl script/update.pl

