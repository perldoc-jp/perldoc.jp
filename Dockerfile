FROM perl:5.36.1-bullseye

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
  apt-get -y upgrade && \
  apt-get install -y wget gcc g++ make sqlite3 cvs

WORKDIR /usr/src/app

COPY cpanfile ./
RUN cpm install

COPY . ./

RUN sqlite3 perldocjp.master.db < sql/sqlite.sql
RUN cp perldocjp.master.db perldocjp.slave.db

ENV PLACK_ENV=docker
ENV PERL5LIB=/usr/src/app/local/lib/perl5
ENV PATH=/usr/src/app/local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# 翻訳データの更新
RUN perl script/update.pl

CMD ["./local/bin/plackup", "-p", "5000", "-Ilib", "app.psgi"]
