perldoc.jp のソースです。

# 自前でうごかす方法

## DBの準備

SQLiteのDBが必要です。DBの場所は、config/development.pl に定義しています。
そのままであれば、ユーザーのホームディレクトリの直下になります。

```sh
test ! -e ~/perldocjp.master.db && sqlite3 ~/perldocjp.master.db < sql/sqlite.sql
cp ~/perldocjp.master.db ~/perldocjp.db
```

## モジュールのインストール

```sh
wget --no-check-certificates http://cpanmin.us
perl cpanm --installdeps .
```

## 翻訳データの取得

cvs と git コマンドが必要です。

```sh
perl scirpt/update.pl
```

で、翻訳されたpodの取得や必要なデータベースの構築を行います。

## plackup の実行

```sh
plackup -p 5000 PJP.psgi
```

勿論、PSGI based なので、Apache ででもなんででもうごきますけども。

## 翻訳データのアップデートをするには

最初の翻訳データの取得と同じです。

```sh
perl ./script/update.pl
```

## デザインを変更するには

デザインの管理には Scss をつかっています。
Scss の生成は gem の Sass が必要なので

```sh
gem install haml
```

して、

```sh
sass  --compass -l --style expanded --watch scss/main.scss:static/css/main.css scss/screen.scss:static/css/screen.css
```

してから変更してください。

main.css の方を変更してはいけません。

## Dotcloud

```sh
# http://packages.ubuntu.com/natty/cvs
curl -LO http://archive.ubuntu.com/ubuntu/pool/main/c/cvs/cvs_1.12.13.orig.tar.gz
tar xzvf ...
curl -LO http://archive.ubuntu.com/ubuntu/pool/main/c/cvs/cvs_1.12.13-12ubuntu1.diff.gz
zcat *.diff.gz | patch -p1
cd ...
./configure --prefix=/home/dotcloud/perl5/
make
make install
```
