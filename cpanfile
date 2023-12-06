requires 'Amon2';
requires 'Text::Xslate';
requires 'Text::Xslate::Bridge::TT2Like';
requires 'Plack::Middleware::ReverseProxy';
requires 'Time::Piece';
requires 'Pod::Simple', '3.16';
requires 'Pod::Simple::XHTML';
requires 'Pod::Perldoc', '3.28';
requires 'Log::Minimal';
requires 'Cache::FileCache';
requires 'CPAN::DistnameInfo';
requires 'LWP::UserAgent';
requires 'URI::Escape';
requires 'Try::Tiny';
requires 'DBD::SQLite';
requires 'SQL::Maker' => 0.14;
requires 'DBIx::TransactionManager';
requires 'Regexp::Common';
requires 'Regexp::Assemble';
requires 'Text::Diff::FormattedHTML';
requires 'Text::Markdown';
requires 'SQL::Interp';
requires 'Carp::Clan';
requires 'JSON';
requires 'File::Find::Rule';
requires 'Module::Find';
requires 'Server::Starter';
requires 'Starlet';
requires 'parent';
requires 'XML::RSS';
requires 'Web::Scraper';
requires 'JSON::XS';
requires 'LWP::UserAgent::WithCache';
requires 'HTML::Entities';
requires 'Router::Simple';
requires 'Router::Simple::Sinatraish';
requires 'Log::Minimal';

on 'test' => sub {
    requires 'Test::WWW::Mechanize::PSGI';
};
