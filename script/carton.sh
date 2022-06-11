#!/bin/sh

export PATH="/opt/local/perl-5.18.2/bin:$PATH"
exec carton exec -- "$@"