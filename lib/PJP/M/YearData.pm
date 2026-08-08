use strict;
use warnings;
use utf8;

package PJP::M::YearData;

# data/years.pl の中身を組み立てる。ファイル入出力は script/create_data.pl
# 側に残し、ここは (翻訳イベント列, seed, 対象年) から年ごとの統計を作る
# 純粋な処理だけを持つ。
#
# $events      : PJP::M::Repository->commit_events の結果。削除・rename で
#                現ツリーから消えた翻訳のイベントも含む
# $seed        : 既存の data/years.pl を読んだもの。初回ビルドでは undef。
#                対象年より前の年だけが取り込まれ、対象年以降のキーは無視される
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

    # seed からは対象年より前の年だけを取り込む。対象年以降は毎回イベントから
    # 再構築する (イベントが削除だけになった年は年ブロックごと消えるべきで、
    # seed 側のブロックを残すと反映されなかった削除が自動コミットで seed に
    # 書き戻され、以後のビルドでも残り続ける)。2011 年より前の統計は、複数の
    # 旧リポジトリを当時のシステムで観測した結果を凍結したもので、現在の
    # git 履歴からは再現できない。
    # 年ブロックは 1 段コピーする。build はブロック直下の modules /
    # commit_count を置き換えるため、seed の hashref を共有すると呼び出し元の
    # seed が壊れる (module の hashref と commit_count_all は読み取りしか
    # しないので共有でよい)。modules は「最初に現れた年に計上する」重複排除に
    # 参加させるため @updates に再注入する
    my $year = {};
    if ($seed) {
        for my $y (grep { $_ < $target_year } keys %$seed) {
            $year->{$y} = { %{$seed->{$y}} };
            push @updates, @{$seed->{$y}{modules}};
        }
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
        # seed 由来で再構築ループに入らなかった年 (modules が空の年) は
        # commit_count が整形済みの ARRAY のまま。そのまま通す
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
