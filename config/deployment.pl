# Cloud Run 用のランタイム設定。
# DB や translation の docs ツリーはビルド時にイメージへ焼き込まれた
# read-only のファイルを参照する (config/build.pl で生成する)。
my $slave_db = '/usr/src/app/db/perldocjp.db';
+{
    slave_db => $slave_db,
    # immutable=1: ファイルが変化しない前提でロック取得や journal 検査を
    # 完全に省略する SQLite の読み取り専用モード
    DBSlave => [
            "dbi:SQLite:uri=file:$slave_db?immutable=1",
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
