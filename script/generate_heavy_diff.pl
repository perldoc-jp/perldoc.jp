#!/usr/bin/perl

use strict;
use warnings;

use utf8;
use lib qw(./lib);
use PJP;
use Module::Find qw/useall/;

useall 'PJP::M';

my ($LIMIT, $SLEEP) = (10, 5);

main();

sub main {
    my $pjp = PJP->bootstrap;
    my $rows = $pjp->dbh_master->search(heavy_diff => { is_cached => 0 });
    my $i = 0;
    while (my $row = $rows->fetchrow_hashref) {
	print "start generate diff(origin:" . $row->{origin} ." / target:" . $row->{target}, ")\n";

        my $diff_info = PJP::M::Pod->diff(@{$row}{qw/origin target/});
        $pjp->dbh_master->replace(heavy_diff => {%$row, diff => $diff_info->{diff}, is_cached => 1, time => time});

	print "finish generate diff\n\n";

        last         if $LIMIT > 0 and $i++ > $LIMIT;
        sleep $SLEEP if $SLEEP;
    }
}
