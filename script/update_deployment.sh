#!/bin/sh

cd /var/lib/jpa/perldoc.jp/code;
export PLACK_ENV=deployment
exec ./script/carton.sh perl script/update.pl
