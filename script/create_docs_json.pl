#!/usr/bin/perl

# pod テーブルの package => path 対応表を static/docs.json に書き出す。
# (script/create_docs.json.sh の VPS 固有パスに依存しない置き換え)
#
# 各 package の path は PJP::M::PodFile->get_latest で解決する。つまり
# docs.json が指す版は、アプリがその package のリクエストで表示する版と
# 常に一致する。SELECT の行順から後勝ちで決めると、結果がスキーマ
# (インデックスの走査順) に依存して古い版に化ける。
# キー順は canonical で固定し、同じ DB からは同じバイト列を生成する。

use strict;
use warnings;

use lib qw(./lib);
use PJP;
use PJP::M::PodFile;
use JSON::XS ();

my $pjp = PJP->bootstrap;

my %docs;
my $packages = $pjp->dbh->selectcol_arrayref('SELECT DISTINCT package FROM pod');
for my $package (@$packages) {
    my $path = PJP::M::PodFile->get_latest($package)
        or die "Cannot resolve the latest path for package: $package";
    $docs{$package} = $path;
}

open my $fh, '>:raw', 'static/docs.json' or die "Cannot open static/docs.json: $!";
print {$fh} JSON::XS->new->canonical->encode(\%docs);
close $fh;
