use strict;
use warnings;
use utf8;

package PJP::M::YearData;

# data/years.pl の中身を組み立てる。ファイル入出力は script/create_data.pl
# 側に持ち、ここは (翻訳イベント列, seed, 対象年) から年ごとの統計を作る。
#
# $events      : PJP::M::Repository->commit_events の結果 (git log の走査順 =
#                配列の先頭側が新しい)。削除・rename で現ツリーから消えた
#                翻訳のイベントも含む
# $seed        : 既存の data/years.pl を読んだもの。初回ビルドでは undef。
#                対象年より前の年だけを引き継ぎ、対象年以降のキーは無視する
# $target_year : 再導出の対象年 (= 前年)。これ以降が git 由来で組み直される

sub build {
    my ($class, $events, $seed, $target_year) = @_;

    # 対象年より前の年は seed をそのまま引き継ぐ
    my %year = map  { $_ => $seed->{$_} }
               grep { $_ < $target_year } keys %{ $seed // {} };

    # 対象年以降を「path ごとの年内最終イベント」に畳む。イベント列は git の
    # 走査順 (新しい方が先) なので、(年, path) の初出が年内最終。年内最終が
    # 削除の path はその年に数えない (年の途中の削除はその年から消え、削除前の
    # 年の実績はイベントがある限り残る)
    my %latest;
    foreach my $event (@$events) {
        my ($y) = $event->{date} =~ m{^(\d+)} or next;
        next if $y < $target_year;
        $latest{$y}{$event->{path}} //= $event;
    }
    my @updates = grep { not $_->{deleted} } map { values %$_ } values %latest;

    # modules は「最初に現れた年に計上する」。seed の modules も初出の判定に
    # 参加させる (同じ dist の同じ版が seed にあれば、対象年以降では初出にならない)
    push @updates, map { @{ $year{$_}{modules} } } keys %year;

    # 古い順に見る。同時刻は path で締めて hash の列挙順に依存させない
    @updates = sort { $b->{date} cmp $a->{date} || $a->{path} cmp $b->{path} } @updates;

    my %seen;
    my %derived;
    foreach my $module (reverse @updates) {
        my ($y) = $module->{date} =~ m{^(\d+)} or next;
        my $n = $module->{in} eq 'perl'
            ? $seen{perl}{$module->{name}}{$module->{version}}++
            : $seen{_dedup_in($module->{in})}{$module->{version}}++;
        next if $y < $target_year;

        my $block = $derived{$y} //= { modules => [], commit_count => {}, commit_count_all => {} };
        if (not $n) {
            push @{ $block->{modules} }, $module;
            $block->{commit_count}{$module->{author}}++;
        }
        $block->{commit_count_all}{$module->{author}}++;
    }

    # commit_count は [author, 全コミット数, 初出 dist 数] を全コミット数の降順
    # (同数は名前順) に並べた配列にする
    foreach my $y (keys %derived) {
        my $block = $derived{$y};
        my $all   = $block->{commit_count_all};
        my $first = $block->{commit_count};
        $block->{commit_count} = [
            map  { [ $_, $all->{$_}, $first->{$_} ] }
            sort { $all->{$b} <=> $all->{$a} || $a cmp $b }
            keys %$all
        ];
        $year{$y} = $block;
    }

    return \%year;
}

# 「同じ dist の同じ版か」の判定に使う in の正規化。in は表示用の文字列で、
# 2022 年以前には旧規則の値 (例: Class::Data-Inheritable、ハイフンを 1 個だけ
# :: にしていたもの) が残っている。表示はそのまま、同一性だけを現行規則
# (全ハイフンを ::) へ寄せ、同じ dist の同じ版が二重計上されないようにする
sub _dedup_in {
    my ($in) = @_;
    $in =~ s{-}{::}g;
    return $in;
}

1;
