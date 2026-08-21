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
    mkdir $assets_dir or die "Cannot mkdir $assets_dir: $!";
}

# 以下の外部コマンドは、失敗しても後続がそれらしく動いてしまう。translation の
# 取得に失敗すれば「翻訳が 1 件も無い」生成物ができ、DB の初期化に失敗すれば
# 空のテーブルに書き込むだけになるので、その場で止める。
#
# 取得の規則 (URL・ref・取得したものが生成の入力として完全かの検査) は
# script/translation.sh に一本化されている。SKIP_ASSETS_UPDATE の扱いも
# そちらが持つ
system("$code_dir/script/translation.sh", 'fetch', "$assets_dir/translation") == 0
    or die "Cannot fetch translation repository";

# code_dir が誤っていても、たまたま正しい cwd から起動していれば以降は
# 成功してしまうので、設定の誤りをここで顕在化させる
chdir $code_dir or die "Cannot chdir to $code_dir: $!";
if (! -e $sqlite_db) {
    system(qq{sqlite3 $sqlite_db < ./sql/sqlite.sql}) == 0
        or die "Cannot initialize $sqlite_db";
}

my $t = time;
PJP::M::BuiltinFunction->generate($pjp);
PJP::M::BuiltinVariable->generate($pjp);
PJP::M::PodFile->generate($pjp);

if ($config->{master_db} and -e $config->{master_db} and $config->{slave_db}) {
  system('cp', $config->{master_db}, $config->{slave_db}) == 0
      or die "Cannot copy $config->{master_db} to $config->{slave_db}";
}

print $mode_name, "\n";
