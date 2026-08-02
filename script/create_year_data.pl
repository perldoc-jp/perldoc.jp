#!/usr/bin/perl

use strict;
use warnings;

use utf8;
use Data::Dumper;
use lib qw(./lib);
use PJP;
use Config::PL;
use Module::Find qw/useall/;

useall 'PJP::M';

local $Data::Dumper::Terse    = 1;
# キー順を決定的にして、data/years.pl を再生成コミットするときの
# diff レビューを可能にする
local $Data::Dumper::Sortkeys = 1;
# author 名など git 由来の文字列が非 ASCII になっても読み手側の
# エンコーディング解釈に依存しないよう、index データ
# (create_index_data.pl) と同じく純 ASCII で出力する
local $Data::Dumper::Useqq    = 1;

main();

sub main {
    my $pjp    = PJP->bootstrap;
    my $events = PJP::M::Repository->commit_events($pjp);
    # イベントが 1 件も無いのは translation checkout の異常。空の統計を
    # 黙って作らず、ビルドを止めて気づけるようにする
    die "no translation events found" unless @$events;

    # 対象年は明示指定がなければ最新の翻訳イベントの前年。壁時計から導出
    # しないことで、同じ translation からのビルドは同じ生成物になる。
    # 当年ターゲットだと年をまたいだ瞬間に前年分が data/years.pl のシード
    # (最終コミット時点) で凍結され、シード更新から年末までの統計が
    # サイレントに欠落するため、前年以降を毎ビルド再導出する
    my $target_year = $ARGV[0] // ($events->[0]{date} =~ m{^(\d+)})[0] - 1;
    create_file($events, $target_year);
}

sub create_file {
    my ($events, $target_year) = @_;
    # 初回ビルド時のみ data/years.pl が存在しない。存在するのに読めない場合は
    # 過去年のデータを黙って失うことになるので config_do に croak させる。
    my $seed = -e 'data/years.pl' ? scalar config_do('data/years.pl') : undef;
    my $year = PJP::M::YearData->build($events, $seed, $target_year);

    # 過去年が欠けたり縮んだりしたら書き出さない。data/years.pl はデプロイ
    # 成功後に master へ自動コミットされて次回ビルドの seed になるため、
    # ここで止めないと誤った生成物が恒久化する (2011 年より前は git 履歴から
    # 再現できない)
    if ($seed) {
        for my $y (grep { $_ < $target_year } keys %$seed) {
            die "year $y is missing from rebuilt years data" if not $year->{$y};
            die "year $y lost modules in rebuild"
                if @{$year->{$y}{modules}} != @{$seed->{$y}{modules}};
        }
    }

    mkdir './data' or die $! if not -d './data';

    open my $fh, '>', "data/years.pl.new" or die $!;
    # 先頭の + は do がブロックと誤解釈しないための明示
    print $fh '+', Dumper($year);
    close $fh;
    rename "data/years.pl.new", "data/years.pl"
        or die "Cannot rename data/years.pl.new to data/years.pl: $!";
}
