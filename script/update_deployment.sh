#!/bin/sh

PLACK_ENV=deployement

cd /var/lib/jpa/perldoc.jp/code;
PERL='/var/lib/jpa/perl5/perls/perl-5.14.2/bin/perl -Mlib=./extlib/lib/perl5 -Ilib'
$PERL script/update.pl

