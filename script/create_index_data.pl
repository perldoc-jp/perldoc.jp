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
use PJP::M::Repository;

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
write_data_pl('data/index-article.pl', { index => [sort_by_updated_at($pjp, \@articles)] });

# その他の翻訳の一覧を「更新が新しい順」に並べる。
#
# 順序の入力は翻訳イベントの日付にする。ファイルの mtime は、生成が cron から
# イメージビルドに移って translation を毎回 clone するようになった時点で
# 「更新が新しい順」を表さなくなった (全ファイルが checkout 時刻に潰れ、
# 同時刻どうしは readdir 順 = 環境依存)。
#
# distvname は articles/ 以下の相対 path なので、docs/ を足すと commit_events が
# 返す path 形式になる。イベントの無い path (履歴が翻訳文書の構成に合わない等) は
# 日付なしとして末尾に送り、同順は distvname で締めて全順序にする。
sub sort_by_updated_at {
    my ($c, $articles) = @_;

    my %updated_at;
    # commit_events は日付の降順なので、path ごとの初出が最新イベント
    my $events = PJP::M::Repository->commit_events($c);
    $updated_at{$_->{path}} //= $_->{date} for @$events;

    return map  { $_->[1] }
           sort { $b->[0] cmp $a->[0] || $a->[1]{distvname} cmp $b->[1]{distvname} }
           map  { [ $updated_at{"docs/articles/$_->{distvname}"} // '', $_ ] } @$articles;
}

# 先頭の + は do がブロックと誤解釈しないための明示。
sub write_data_pl {
    my ($path, $data) = @_;
    open my $fh, '>', "$path.new" or die "Cannot open $path.new: $!";
    print {$fh} '+', Dumper($data);
    close $fh;
    rename "$path.new", $path or die "Cannot rename $path.new to $path: $!";
}
