#!/bin/sh

sqlite3 ../db/perldocjp.db  'select package,path from pod' | ./script/carton.sh perl -e 'use JSON::XS qw/encode_json/; my %d; while(<>) {chomp; my($m, $p) = split "\\|", $_, 2; $d{$m} = $p} print encode_json(\%d)' > /tmp/perldoc.jp.docs.json
mv /tmp/perldoc.jp.docs.json /var/lib/jpa/perldoc.jp/code/static/docs.json
