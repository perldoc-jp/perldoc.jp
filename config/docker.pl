use Cwd ();

my $master_db = '/usr/src/app/perldocjp.master.db';
my $slave_db  = '/usr/src/app/perldocjp.slave.db';

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
        path => ['tmpl/'],
        cache_dir => "/usr/src/app/tmp/perldoc.jp-xslate.cache/",
    },
    'assets_dir' => "/usr/src/app/assets/",
    # qx/pwd/ だと末尾に改行が付き、chdir がそのまま失敗する
    'code_dir'   => Cwd::getcwd(),
};
