#!/bin/sh

cd /var/lib/jpa/perldoc.jp/code;
PLACK_ENV=deployment ./script/carton.sh script/update.pl
