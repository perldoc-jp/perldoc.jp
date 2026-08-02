use strict;
use warnings;
use utf8;

package PJP::M::YearData;

# data/years.pl の中身を組み立てる。ファイル入出力は script/create_year_data.pl
# 側に残し、ここは (翻訳イベント列, seed, 対象年) から年ごとの統計を作る
# 純粋な処理だけを持つ。
#
# $events      : PJP::M::Repository->commit_events の結果。削除・rename で
#                現ツリーから消えた翻訳のイベントも含む
# $seed        : 既存の data/years.pl を読んだもの。初回ビルドでは undef
# $target_year : 再導出の対象年 (= 前年)。これ以降が git 由来で組み直される
sub build {
    my ($class, $events, $seed, $target_year) = @_;

    # 対象年以降を「path ごとの年内最終イベント」に畳む。年内最終が削除の
    # path はその年に数えない。旧 VPS が毎日の観測で当年を上書きし年末時点の
    # 状態を凍結していたのと同じ意味論になる (年の途中の削除はその年から
    # 消え、削除前の年の実績はイベントがある限り残る)
    my %latest;
    foreach my $event (@$events) {
        my ($y) = $event->{date} =~ m{^(\d+)} or next;
        next if $y < $target_year;
        my $found = $latest{$y}{$event->{path}};
        $latest{$y}{$event->{path}} = $event if not $found or $event->{date} gt $found->{date};
    }
    my @updates = grep { not $_->{deleted} } map { values %$_ } values %latest;

    my $year = $seed // {};
    if ($seed) {
        # 対象年より前は git から再導出しないので seed をそのまま再注入する。
        # 2011 年より前の統計は、複数の旧リポジトリを当時のシステムで観測した
        # 結果を凍結したもので、現在の git 履歴からは再現できない
        push @updates, map { @{$year->{$_}->{modules}} } grep { $_ < $target_year } keys %$year;
    }

    # 全体を一度に並べ替える。「最初に現れた年に計上する」規則は下の reverse に
    # 依存しているので、ブロックを継ぎ足した順序に任せると後から push した分が
    # 先頭に来て古い年の実績を横取りする。path のタイブレークは同時刻エントリの
    # 順序を hash の列挙順に依存させないため
    @updates = sort { $b->{date} cmp $a->{date} || $a->{path} cmp $b->{path} } @updates;

    my %first;
    my %module;
    foreach my $module (reverse @updates) {
        my ($y) = $module->{date} =~ m{^(\d+)} or next;
        if (not $first{$y}++) {
            $year->{$y}->{modules}      = [];
            $year->{$y}->{commit_count} = {};
            if ($y >= $target_year) {
                $year->{$y}->{commit_count_all} = {};
            }
        }
        my $n = $module->{in} eq 'perl'
            ? $module{perl}->{$module->{name}}->{$module->{version}}++
            : $module{$module->{in}}->{$module->{version}}++;
        if (not $n) {
            push @{$year->{$y}->{modules}}, $module;
            $year->{$y}->{commit_count}->{$module->{author}}++;
        }
        if ($y >= $target_year) {
            $year->{$y}->{commit_count_all}->{$module->{author}}++;
        }
    }

    foreach my $y (keys %$year) {
        my %tmp;
        next if ref $year->{$y}->{commit_count} ne 'HASH';
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

    return $year;
}

1;
