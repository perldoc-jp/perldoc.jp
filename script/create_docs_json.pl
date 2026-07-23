#!/usr/bin/perl

# pod テーブルの package => path 対応表を static/docs.json に書き出す。
# (script/create_docs.json.sh の VPS 固有パスに依存しない置き換え)

use strict;
use warnings;

use lib qw(./lib);
use PJP;
use JSON::XS qw/encode_json/;

my $pjp = PJP->bootstrap;

my %docs;
my $sth = $pjp->dbh->prepare('SELECT package, path FROM pod');
$sth->execute;
while (my ($package, $path) = $sth->fetchrow_array) {
    $docs{$package} = $path;
}

open my $fh, '>:raw', 'static/docs.json' or die "Cannot open static/docs.json: $!";
print {$fh} encode_json(\%docs);
close $fh;
