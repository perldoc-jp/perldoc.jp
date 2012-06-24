+{
	DB => [
		'dbi:SQLite:dbname=/tmp/pjp.db',
		'',
		'',
	],
    'Text::Xslate' => {
        path => ['tmpl/'],
    },
    'assets_dir' => "$ENV{HOME}/assets/",
};
