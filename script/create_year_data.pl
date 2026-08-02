#!/usr/bin/perl

use strict;
use warnings;

use utf8;
use Data::Dumper;
use Time::Piece;
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

my %IGNORE_FILES = (
    'modules/CGI-FastTemplate-1.09/README' => 1,
    'modules/translation_table.md' => 1,
    'modules/translation-tutorial.md' => 1,
    );

main();

sub main {
    my $pjp  = PJP->bootstrap;
    my $year = $ARGV[0] or die "year is needed\n";
    my $since = Time::Piece->strptime("$year-01-01 00:00:00",         '%Y-%m-%d %H:%M:%S');
    my $until = Time::Piece->strptime(($year + 1) . "-01-01 00:00:00", '%Y-%m-%d %H:%M:%S');
    # ターゲット年は年末 (until) で打ち切って「その年の最終状態」を導出する。
    # 打ち切らずに 1 回の git log -1 でまとめて取ると、翌年に再修正された
    # ファイルは最新コミット (翌年) の日付だけが返り、ターゲット年の記録から
    # 消えてしまう (VPS が毎日の実行で年末時点の状態を凍結していたのと
    # 同じ結果になるよう、年内最後のコミットを別窓で取る)。
    # git の --since / --until は両端を含むので、2 窓を [since, until) と
    # [until, ) の半開区間にしないと元日 00:00:00 ちょうどのコミットが
    # 両方に入り、commit_count_all が二重に加算される
    my $updates = PJP::M::Repository->recent_data($pjp, $since, $until - 1);
    push @$updates, @{ PJP::M::Repository->recent_data($pjp, $until) };
    create_file($updates, $year, PJP::M::Repository->current_paths($pjp));
    update_pod_update_time($pjp, $updates);
}

sub update_pod_update_time {
    my ($pjp, $updates) = @_;
    foreach my $update (@$updates) {
	next if $update->{path} =~ m{\.zip$} or $update->{path} =~ m{\.pot?$} or $update->{path} =~m{pod\.org$};

	$update->{path} =~s{^docs/}{};
	$update->{path} =~s{^modules/docs/}{};
	$update->{path} =~s{^core/}{perl/};
	$update->{path} =~s{^modules/(\w+)\.pm(-[\d.]+)}{modules/$1$2};

	if (my $data = PJP::M::PodFile->retrieve($update->{path})) {
	    $data->{update_time} = Time::Piece->strptime($update->{date}, '%Y-%m-%d %H:%M:%S')->epoch;
	    $pjp->dbh_master->replace(pod => $data);
	} else {
	    next if $IGNORE_FILES{$update->{path}};
	    warn "the path cannot be found in DB: " . $update->{path};
	}
    }
}

sub create_file {
    my ($updates, $target_year, $current_paths) = @_;
    # 初回ビルド時のみ data/years.pl が存在しない。存在するのに読めない場合は
    # 過去年のデータを黙って失うことになるので config_do に croak させる。
    my $seed = -e 'data/years.pl' ? scalar config_do('data/years.pl') : undef;
    my $year = PJP::M::YearData->build($updates, $seed, $target_year, $current_paths);

    mkdir './data' or die $! if not -d './data';

    open my $fh, '>', "data/years.pl.new" or die $!;
    # 先頭の + は do がブロックと誤解釈しないための明示
    print $fh '+', Dumper($year);
    close $fh;
    rename "data/years.pl.new", "data/years.pl"
        or die "Cannot rename data/years.pl.new to data/years.pl: $!";
}

