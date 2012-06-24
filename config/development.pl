+{
       DB => [
                "dbi:SQLite:dbname=$ENV{HOME}/perldocjp.db",
                '',
                '',
       ],
    'Text::Xslate' => {
        path => ['tmpl/'],
    },
    'assets_dir' => "$ENV{HOME}/assets/",
    'code_dir'   => qx/pwd/,
};
