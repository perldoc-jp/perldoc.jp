#!/bin/sh

export PATH="/opt/local/perl-5.16/bin:$PATH"
exec carton install $@

