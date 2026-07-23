#!/usr/bin/perl

# /index/module と /index/article の目次データを data/ に書き出す。
# 目次の事前生成は #55/#56 で「cron での index ファイル生成と相性が悪い」
# ため実行時キャッシュに変更されたが、データ更新がイメージ再ビルド
# (databuild) に一本化されたことで前提が変わったため、ビルド時生成に戻す。

use strict;
use warnings;

use Data::Dumper;
use lib qw(./lib);
use PJP;
use PJP::M::Index::Module;
use PJP::M::Index::Article;

local $Data::Dumper::Terse    = 1;
local $Data::Dumper::Indent   = 1;
local $Data::Dumper::Sortkeys = 1;
# abstract には Encode::decode 済みの日本語 (wide) 文字列が含まれるため、
# 非 ASCII を \x{} 等でエスケープした純 ASCII で出力し、Data::Dumper の
# 実装 (XS/PP) に依存しないラウンドトリップにする。ファイルに use utf8
# ヘッダを書く方式は、読み手の config_do が do 時に @INC を cwd に限定
# するため「利用側プロセスが utf8.pm をロード済みか」に成否が依存して
# しまい使えない (素の生バイト出力は data/recent.pl のような ASCII のみの
# ペイロードでしか成立しない)。
local $Data::Dumper::Useqq    = 1;

my $pjp = PJP->bootstrap;

mkdir './data' or die $! if not -d './data';

my @modules = PJP::M::Index::Module->generate($pjp);
die "PJP::M::Index::Module->generate returned no entries" unless @modules;
write_data_pl('data/index-module.pl', { index => \@modules });

my @articles = PJP::M::Index::Article->generate($pjp);
die "PJP::M::Index::Article->generate returned no entries" unless @articles;
write_data_pl('data/index-article.pl', { index => \@articles });

# 先頭の + は do がブロックと誤解釈しないための明示。
sub write_data_pl {
    my ($path, $data) = @_;
    open my $fh, '>', "$path.new" or die "Cannot open $path.new: $!";
    print {$fh} '+', Dumper($data);
    close $fh;
    rename "$path.new", $path or die "Cannot rename $path.new to $path: $!";
}
