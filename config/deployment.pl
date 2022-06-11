my $master_db = '/var/lib/jpa/perldoc.jp/db/perldocjp.db';
my $slave_db  = '/var/lib/jpa/perldoc.jp/db/perldocjp.slave.db';
+{
    master_db => $master_db,
    slave_db  => $slave_db,
    DB => [
            "dbi:SQLite:dbname=" . $master_db,
            '',
            '',
    ],
    DBSlave => [
            "dbi:SQLite:dbname=" . $slave_db,
            '',
            '',
    ],
    'Text::Xslate' => {
        cache_dir => "/tmp/perldoc.jp-xslate.cache/",
    },
    'assets_dir' => "/var/lib/jpa/perldoc.jp/assets/",
    'code_dir'   => "/var/lib/jpa/perldoc.jp/code/",
    'perl'       => "/opt/local/perl-5.18.2/bin -Mlib=./local/lib/perl5 -Ilib",
};
