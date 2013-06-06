use File::Spec;
use File::Basename;
use PJP::Web;
use Plack::Builder;
use Log::Minimal;

builder {
    enable 'Plack::Middleware::Static',
        path => qr{^(/static/|/favicon\.ico|/robots\.txt)},
        root => './';
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
