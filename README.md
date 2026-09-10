# NAME

perldoc.jp のソース

# DESCRIPTION

Perl の公式ドキュメントとモジュールドキュメントの日本語訳を表示するサイト
perldoc.jp のソースコードです。

# ARCHITECTURE

perldoc.jp の翻訳データは、https://github.com/perldoc-jp/translation から取得して
SQLite に保存し、それを表示しています。

組み込み関数や組み込み変数などの一覧情報は、perldoc の出力を元に生成しています。

Google Cloud Run 上で動作しています。翻訳データや一覧情報はイメージのビルド時に
生成して焼き込むので、配信するデータの更新はイメージの再ビルドと再デプロイで行います。
構成と運用は [docs/cloud-run.md](docs/cloud-run.md) を参照してください。

# WORKFLOW

修正したい点があれば、プルリクエストを送ってください。

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

## Carmel や Carton を利用する場合

- Requirements
  - Git
  - SQLite client
  - Carmel or Carton

### 下準備

#### DBの準備

SQLite の DB が必要です。DB の場所は config/development.pl に定義してあり、
そのままであればユーザーのホームディレクトリの直下になります。

```sh
test ! -e ~/perldocjp.master.db && sqlite3 ~/perldocjp.master.db < sql/sqlite.sql
cp ~/perldocjp.master.db ~/perldocjp.db
```

#### モジュールのインストール

```sh
carmel install
```

#### 翻訳データの取得

`config/development.pl` の `assets_dir` は変更しておくことをおすすめします (デフォルトでは、ホームディレクトリの直下に `assets` というディレクトリが必要になります)。

```sh
# 翻訳されたpodの取得や必要なデータベースの構築
# 翻訳データを更新したい場合もこのコマンドを実行します
perl script/update.pl
```

翻訳データは更新せず、関連するファイルや DB だけを更新したい場合は、環境変数 `SKIP_ASSETS_UPDATE=1` を設定してください。

### 開発をする

```sh
# サーバーの起動
carmel exec -- plackup -Ilib -p 5000 app.psgi

# テストを回す
carmel exec -- prove -Ilib -r -v t
```

### デザインを変更する場合の環境構築

デザインの管理には Scss を使っています。CSS の生成には gem の Sass が必要です。

```sh
gem install haml
```

次のコマンドで scss/ の変更を監視しながら編集します。

```sh
sass  --compass -l --style expanded --watch scss/main.scss:static/css/main.css scss/screen.scss:static/css/screen.css
```

static/css/main.css と screen.css はこのコマンドの生成物なので、直接は編集しません。

