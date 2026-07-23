# Docker イメージビルド時のデータ生成 (script/update.pl 等) 用の設定。
# script/update.pl が DB の DSN から dbname= でファイルパスを取り出すため、
# ここでは uri= 形式ではなく dbname= 形式を使う。
my $master_db = '/usr/src/app/db/perldocjp.master.db';
my $slave_db  = '/usr/src/app/db/perldocjp.db';
+{
    master_db => $master_db,
    slave_db  => $slave_db,
    DB => [
            "dbi:SQLite:dbname=$master_db",
            '',
            '',
    ],
    DBSlave => [
            "dbi:SQLite:dbname=$slave_db",
            '',
            '',
    ],
    'Text::Xslate' => {
        path      => ['tmpl/'],
        cache_dir => '/tmp/perldoc.jp-xslate.cache/',
    },
    'assets_dir' => '/usr/src/app/assets/',
    'code_dir'   => '/usr/src/app/',
};
