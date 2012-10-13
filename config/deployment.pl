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
    'perl'       => "/var/lib/jpa/perl5/perls/perl-5.14.2/bin/perl -Mlib=./extlib/lib/perl5 -Ilib",
};
