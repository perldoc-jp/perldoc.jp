package PJP::Util;

use strict;
use warnings;
use feature qw(state);
use parent 'Exporter';

use Text::Markdown::Discount ();

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
    my ($markdown) = @_;

    state $flag = Text::Markdown::Discount::MKD_NOHEADER
                | Text::Markdown::Discount::MKD_NOPANTS
                | 0x02000000 # MKD_FENCEDCODE
                ;

    my $html = Text::Markdown::Discount::markdown($markdown, $flag);

    # perldoc.jp 用の加工
    $html =~ s{^.*<(?:body)[^>]*>}{}si;
    $html =~ s{</(?:body)>.*$}{}si;
    $html =~ s{<!--\s+original(.*?)-->}{<div class="original">$1</div>}sg;

    return $html;
}

1;

