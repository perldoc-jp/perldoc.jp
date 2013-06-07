#!/bin/sh

cd /var/lib/jpa/perldoc.jp/code
export PLACK_ENV=deployment
export PATH="/opt/local/perl-5.16/bin:$PATH"

sqlite3 ../db/perldocjp.db  'select package,path from pod' | carton exec -Ilib -- perl -e 'use JSON::XS qw/encode_json/; my %d; while(<>) {chomp; my($m, $p) = split "\\|", $_, 2; $d{$m} = $p} print encode_json(\%d)' > /tmp/perldoc.jp.docs.json
mv /tmp/perldoc.jp.docs.json /var/lib/jpa/perldoc.jp/code/static/docs.json
