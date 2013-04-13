package PJP::Util;

use strict;
use warnings;
use parent 'Exporter';

our @EXPORT_OK = qw/slurp/;

sub slurp {
    if (@_==1) {
        my ($stuff) = @_;
        open my $fh, '<', $stuff or die "Cannot open file: $stuff";
        do { local $/; <$fh> };
    } else {
        die "not implemented yet.";
    }
}

1;

