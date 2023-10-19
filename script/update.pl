#!/usr/bin/perl

use strict;
use warnings;

use Encode qw/encode_utf8/;
use Log::Minimal;
local $Log::Minimal::PRINT = sub {
    my ( $time, $type, $message, $trace, $raw_message) = @_;
    $message = encode_utf8($message);
    warn "$time [$type] $message at $trace\n";
};

use lib qw(./lib);
use PJP;
use Module::Find qw/useall/;
useall 'PJP::M';

my $pjp	       = PJP->bootstrap;
my $config     = $pjp->config;
my $mode_name  = $pjp->mode_name || 'development';

my $assets_dir = $config->{'assets_dir'} || die "no assets_dir setting in config/" . $mode_name . '.pl';
my $code_dir   = $config->{'code_dir'}   || die "no code_dir setting in config/"   . $mode_name . '.pl';
my $perl       = $config->{perl} || 'perl -Ilib';
my($sqlite_db) = $config->{DB}->[0] =~m{dbname=(.+)$};

foreach my $db_type (qw/master_db slave_db/) {
    if ( not -e $config->{$db_type} ) {
        die "prepare database at first. not found database: " . $config->{$db_type};
    }
}

if (! -d $assets_dir) {
    mkdir $assets_dir;
}

#if (! $ENV{SKIP_ASSETS_UPDATE}) {
#    if (! -d $assets_dir . '/perldoc.jp/') {
#
#        mkdir $assets_dir . '/perldoc.jp/';
#        system(<<_SHELL_);
#    cd $assets_dir/perldoc.jp;
#    cvs -d:pserver:anonymous\@cvs.sourceforge.jp:/cvsroot/perldocjp login;
#    cvs -z3 -d:pserver:anonymous\@cvs.sourceforge.jp:/cvsroot/perldocjp co docs;
#_SHELL_
#
#    } else {
#        system(qq{cd $assets_dir/perldoc.jp/docs/; cvs up -dP});
#    }
#}

if (! -d $assets_dir . '/translation/') {
    system(qq{git clone https://github.com/perldoc-jp/translation.git $assets_dir/translation/});
}

if (! $ENV{SKIP_ASSETS_UPDATE}) {
    system(qq{cd $assets_dir/translation; git pull origin master});
}

unlink "$assets_dir/index-module.pl";
unlink "$assets_dir/index-article.pl";

chdir $code_dir;
if (! -e $sqlite_db) {
    system(qq{sqlite3 $sqlite_db < ./sql/sqlite.sql});
}

my $t = time;
PJP::M::Index::Article->generate_and_save($pjp);
PJP::M::Index::Module->generate_and_save($pjp);
PJP::M::BuiltinFunction->generate($pjp);
PJP::M::BuiltinVariable->generate($pjp);
PJP::M::PodFile->generate($pjp);

if ($config->{master_db} and -e $config->{master_db} and $config->{slave_db}) {
  system('cp ' . $config->{master_db} . ' ' . $config->{slave_db});
}

print $mode_name, "\n";
