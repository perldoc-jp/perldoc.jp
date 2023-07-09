my $master_db = "$ENV{HOME}/perldocjp.master.db";
my $slave_db  = "$ENV{HOME}/perldocjp.db";

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
        cache_dir => './xtc',
    },
    'assets_dir' => "$ENV{HOME}/assets/",
    'code_dir'   => qx/pwd/,
};
