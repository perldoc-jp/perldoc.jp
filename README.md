# NAME

perldoc.jp のソース

# DESCRIPTION

Perl の公式ドキュメント、モジュールドキュメントを日本語に翻訳したものを表示するサイト
perldoc.jp のソースコードです

# ARCHITECTURE

perldoc.jpの翻訳データは、https://github.com/perldoc-jp/translation から取得し、
SQLiteに保存しておき、それを表示しています。

組み込み関数や組み込み変数などの一覧情報は、perldocの情報を元に生成しています.

Google Cloud Run 上で動作しています。翻訳データや一覧情報はイメージのビルド時に
生成して焼き込むので、配信するデータの更新はイメージの再ビルドと再デプロイで行います。
構成と運用は [docs/cloud-run.md](docs/cloud-run.md) を参照してください。

# WORKFLOW

修正したい点があれば、プルリクエストを送ってください。

依存モジュールの更新は Renovate が毎月自動でプルリクエストを作ります。
対象と設定は [docs/dependency-updates.md](docs/dependency-updates.md) を参照してください。

# SETUP

## Docker を利用する場合

- Requirements
  - Docker
  - docker-compose v3 


```shell
# サーバーを立ち上げる
make up

# 翻訳データと、それに依存する生成物 (data/ や static/docs.json) を作る。
# 立ち上げた直後は生成物が無く、トップページや一覧が表示できない
make setup-data

# サーバーを落とす
make down

# テストを回す
make test
```

## Carmel や Cartonを利用する場合

- Requirements
  - Git
  - SQLite client
  - Carmel or Carton

### 下準備

#### DBの準備

SQLiteのDBが必要です。DBの場所は、config/development.pl に定義しています。
そのままであれば、ユーザーのホームディレクトリの直下になります。

```sh
test ! -e ~/perldocjp.master.db && sqlite3 ~/perldocjp.master.db < sql/sqlite.sql
cp ~/perldocjp.master.db ~/perldocjp.db
```

#### モジュールのインストール

```sh
carmel install
```

#### 翻訳データの取得

※ `conf/development.pl` の `assets_dir` を変更しておくのをおすすめします(デフォルトでは、ホームディレクトリの直下に `assets` というディレクトリが必要になります)。

```sh
# 翻訳されたpodの取得や必要なデータベースの構築
# 翻訳データを更新したい場合もこのコマンドを実行します
perl script/update.pl
```

※翻訳データのアップデートを行いたくないが、関連するファイルやDBのみ更新したい場合は、`SKIP_ASSETS_UPDATE=1`を環境変数に設定してください。

### 開発をする

```sh
# サーバーの起動
carmel exec -- plackup -Ilib -p 5000 app.psgi

# テストを回す
carmel exec -- prove -Ilib -r -v t
```

### デザインを変更する場合の環境構築

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

