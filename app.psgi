use File::Spec;
use File::Basename;
use PJP::Web;
use Plack::Builder;
use Plack::Util;
use Log::Minimal;

# 静的ファイルの Cache-Control。ファイル名にダイジェストが入らないので恒久
# キャッシュにはせず、デプロイ後に自然に入れ替わる長さに留める。docs.json と
# rss はビルドごとに変わるため短くする (Cloudflare の Edge TTL と揃える)
my $STATIC_MAX_AGE    = 14400;
my $GENERATED_MAX_AGE = 7200;

sub static_max_age {
    my $path = shift;
    return $GENERATED_MAX_AGE if $path eq '/static/docs.json';
    return $GENERATED_MAX_AGE if $path =~ m{\A/static/rss/};
    return $STATIC_MAX_AGE    if $path =~ m{\A/static/} or $path eq '/favicon.ico';
    return undef;
}

builder {
    # Static より外側に置き、配信されたレスポンスにヘッダを足す
    enable sub {
        my $app = shift;
        sub {
            my $env     = shift;
            my $max_age = static_max_age($env->{PATH_INFO});
            return $app->($env) unless defined $max_age;
            Plack::Util::response_cb($app->($env), sub {
                my $res = shift;
                return unless $res->[0] == 200;
                Plack::Util::header_set($res->[1], 'Cache-Control', "public, max-age=$max_age");
            });
        };
    };
    enable 'Plack::Middleware::Static',
        path => qr{^(/static/|/robots\.txt)},
        root => './';
    # favicon.ico の実体は static/ にしか無いので root を分ける
    enable 'Plack::Middleware::Static',
        path => qr{^/favicon\.ico$},
        root => './static/';
    enable 'Plack::Middleware::ReverseProxy';
    enable sub {
        my $app = shift;
        sub {
            my $env = shift;
            local $Log::Minimal::PRINT = sub {
                my ($time, $type, $message, $trace, $raw_message) = @_;
                print STDERR sprintf("[%s] [%s] %s at %s by '%s'\n", $type, $env->{REQUEST_URI}, $message, $trace, $env->{HTTP_USER_AGENT});
            };
            $app->($env);
        };
    };

    PJP::Web->to_app();
};
