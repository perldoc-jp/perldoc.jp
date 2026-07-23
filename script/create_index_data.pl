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

my $pjp = PJP->bootstrap;

mkdir './data' or die $! if not -d './data';

my @modules = PJP::M::Index::Module->generate($pjp);
die "PJP::M::Index::Module->generate returned no entries" unless @modules;
write_data_pl('data/index-module.pl', { index => \@modules });

my @articles = PJP::M::Index::Article->generate($pjp);
die "PJP::M::Index::Article->generate returned no entries" unless @articles;
write_data_pl('data/index-article.pl', { index => \@articles });

# Config::PL (config_do → do) で読み戻すファイルを書く。
# abstract には Encode::decode 済みの日本語 (wide) 文字列が含まれるため、
# use utf8 ヘッダ + :encoding(UTF-8) で書き出し、do 時にファイル自身の
# プラグマで文字列として復元させる。data/recent.pl はペイロードが ASCII
# のみなので素の Dumper で足りているが、ここで同じ方式を使うと
# Data::Dumper の実装 (XS は \x{} エスケープ / PP は生出力) に挙動が
# 依存してしまう。先頭の + は do がブロックと誤解釈しないための明示。
sub write_data_pl {
    my ($path, $data) = @_;
    open my $fh, '>:encoding(UTF-8)', "$path.new" or die "Cannot open $path.new: $!";
    print {$fh} "use utf8;\n+", Dumper($data);
    close $fh;
    rename "$path.new", $path or die "Cannot rename $path.new to $path: $!";
}
