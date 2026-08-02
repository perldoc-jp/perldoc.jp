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
    my $year = -e 'data/years.pl' ? scalar config_do('data/years.pl') : undef;
    if ($year) {
        # 対象年より前は git から再導出しないので seed をそのまま再注入する
        push @$updates, map { @{$year->{$_}->{modules}} } grep {$_ < $target_year} keys %$year;
        # 対象年以降は git から再導出するが、recent_data が列挙するのは現在の
        # checkout に実在するファイルだけなので、削除・rename された翻訳は
        # 再導出では拾えない。seed を残さないとその年の統計から恒久的に落ち、
        # しかも欠損したまま deploy.yml が master へ書き戻してしまう
        push @$updates, grep { not $current_paths->{$_->{path}} }
                        map  { @{$year->{$_}->{modules}} } grep {$_ >= $target_year} keys %$year;
    } else {
        $year = {};
    }
    # 全体を一度に並べ替える。「最初に現れた年に計上する」規則は下の reverse に
    # 依存しているので、ブロックを継ぎ足した順序に任せると後から push した分が
    # 先頭に来て古い年の実績を横取りする。path のタイブレークは同時刻エントリの
    # 順序を keys の列挙順に依存させないため
    @$updates = sort { $b->{date} cmp $a->{date} || $a->{path} cmp $b->{path} } @$updates;
    my %first;
    my %module;

    foreach my $module (reverse @$updates) {
        if ($module->{date} =~m{^(\d+)}) {
            my $y = $1;
            if (not $first{$y}++) {
                $year->{$y}->{modules}          = [];
                $year->{$y}->{commit_count}     = {};
                if ($y >= $target_year) {
                    $year->{$y}->{commit_count_all} = {};
                }
            }
            my $n;
            if ($module->{in} eq 'perl') {
                $n = $module{perl}->{$module->{name}}->{$module->{version}}++;
            } else {
                $n = $module{$module->{in}}->{$module->{version}}++;
            }
            if (not $n) {
                push @{$year->{$y}->{modules}}, $module;
                $year->{$y}->{commit_count}->{$module->{author}}++;
                if ($y >= $target_year) {
                    $year->{$y}->{commit_count_all}->{$module->{author}}++;
                }
            } else {
                if ($y >= $target_year) {
                    $year->{$y}->{commit_count_all}->{$module->{author}}++;
                }
            }
        }
    }

    foreach my $y (keys %$year) {
        my %tmp;
        if (ref $year->{$y}->{commit_count} eq 'HASH') {
            $year->{$y}->{commit_count} =
                [
                 map {
                     [ $_, $year->{$y}->{commit_count_all}->{$_}, $year->{$y}->{commit_count}->{$_} ]
                 }
                 sort {
                     # 同数のときは名前順で決定的にする
                     ($tmp{$b} ||= $year->{$y}->{commit_count_all}->{$b})
                         <=>
                     ($tmp{$a} ||= $year->{$y}->{commit_count_all}->{$a})
                         || $a cmp $b
                 } keys %{$year->{$y}->{commit_count_all}}
                ];
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

