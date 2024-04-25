package PJP::Util;

use strict;
use warnings;
use feature qw(state);
use parent 'Exporter';

use Markdent::Simple::Document;

our @EXPORT_OK = qw/slurp markdown_to_html/;

sub slurp {
    if (@_==1) {
        my ($stuff) = @_;
        open my $fh, '<', $stuff or die "Cannot open file: $stuff";
        do { local $/; <$fh> };
    } else {
        die "not implemented yet.";
    }
}

sub markdown_to_html {
    my ($markdown, $title) = @_;
    $title //= 'PJP';

    state $parser = Markdent::Simple::Document->new;
    my $html = $parser->markdown_to_html(
        title    => $title,
        dialect  => 'GitHub',
        markdown => $markdown,
    );

    # perldoc.jp 用の加工
    $html =~ s{^.*<(?:body)[^>]*>}{}si;
    $html =~ s{</(?:body)>.*$}{}si;
    $html =~ s{<!--\s+original(.*?)-->}{<div class="original">$1</div>}sg;

    return $html;
}

1;

