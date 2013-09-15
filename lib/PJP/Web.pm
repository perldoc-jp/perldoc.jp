package PJP::Web;
use strict;
use warnings;
use parent qw/PJP Amon2::Web/;
use Log::Minimal;
use Amon2::Declare;
use Regexp::Common qw/URI/;

# load all controller classes
use Module::Find ();
Module::Find::useall("PJP::Web::C");

# custom classes
use PJP::Web::Request;
use PJP::Web::Response;
sub create_request  { PJP::Web::Request->new($_[1]) }
sub create_response { shift; PJP::Web::Response->new(@_) }

# dispatcher
use PJP::Web::Dispatcher;
sub dispatch {
    return PJP::Web::Dispatcher->dispatch($_[0]) or die "response is not generated";
}

# setup view class
use Text::Xslate;
{
    my $view_conf = __PACKAGE__->config->{'Text::Xslate'} || die "missing configuration for Text::Xslate";
    my $view = Text::Xslate->new(+{
        'syntax'   => 'TTerse',
        'module'   => [ 'Text::Xslate::Bridge::TT2Like' ],
        path       => ['./tmpl/'],
        'function' => {
            c => sub { Amon2->context() },
            uri_with => sub { Amon2->context()->req->uri_with(@_) },
            uri_for  => sub { Amon2->context()->uri_for(@_) },
            url_to_link => sub {
               my ($text) = @_;
	       if ($text) {
		   my $url_regexp = $RE{URI}{HTTP}{-scheme => 'https?'}{-keep};
		   $text = Text::Xslate::Util::html_escape($text);
		   $text =~s{$url_regexp}{
		       my ($url, $host) = ($1, $3);
		       my ($file) = $url =~m{/([^/]+?\.[^/]+)$};
		       qq{ <a href="$url" target="_blank">} . ($file ? qq{$file ($host)} : $url) . q{</a> }
		   }gex;
		   $text = Text::Xslate::Util::mark_raw($text);
	       }
	       return $text;
            },
        },
        warn_handler => sub { print STDERR sprintf("[WARN] [%s] %s", c->req->path_info, $_[0]) },
        die_handler  => sub { print STDERR sprintf("[DIE]  [%s] %s", c->req->path_info, $_[0]) },
        %$view_conf
    });
    sub create_view { $view }
}

sub show_error {
    my ($c, $msg) = @_;
    $c->render('error.tt', {message => $msg});
}

sub res_404 {
    my ($c, $msg) = @_;
    $c->render_with_status(404, '404.tt', {message => $msg});
}

sub render_with_status {
    my $self   = shift;
    my $status = shift;
    my $html = $self->create_view()->render(@_);

    for my $code ($self->get_trigger_code('HTML_FILTER')) {
        $html = $code->($self, $html);
    }

    $html = $self->encode_html($html);

    return $self->create_response(
        $status,
        [
            'Content-Type'   => $self->html_content_type,
            'Content-Length' => length($html)
        ],
        $html,
    );
}

sub show_403 {
    my ($c) = @_;
    return $c->create_response(403, ['Content-Type' => 'text/html; charset=utf-8'], ['forbidden']);
}

1;
