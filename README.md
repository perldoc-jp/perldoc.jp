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

git コマンドが必要です。

※ `conf/development.pl` の `assets_dir` を変更しておくのをおすすめします(デフォルトでは、ホームディレクトリの直下に `assets` というディレクトリが必要になります)。

```sh
perl script/update.pl
```

で、翻訳されたpodの取得や必要なデータベースの構築を行います。

## plackup の実行

```sh
plackup -Ilib -p 5000 app.psgi
```

勿論、PSGI based なので、Apache ででもなんででもうごきますけども。

## 翻訳データのアップデートをするには

最初の翻訳データの取得と同じです。

```sh
perl ./script/update.pl
```

※翻訳データのアップデートを行いたくないが、関連するファイルやDBのみ更新したい場合は、`SKIP_ASSETS_UPDATE=1`を環境変数に設定してください。

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

