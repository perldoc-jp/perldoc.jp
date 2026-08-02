use strict;
use warnings;
use utf8;

package PJP::M::YearData;

# data/years.pl の中身を組み立てる。ファイル入出力は script/create_year_data.pl
# 側に残し、ここは (再導出結果, seed, 対象年, 現ツリーの path) から
# 年ごとの統計を作る純粋な処理だけを持つ。
#
# $updates      : PJP::M::Repository->recent_data の結果を連結したもの
#                 (対象年以降を git から再導出したエントリ)
# $seed         : 既存の data/years.pl を読んだもの。初回ビルドでは undef
# $target_year  : 再導出の対象年 (= 前年)。これ以降が git 由来で組み直される
# $current_paths: PJP::M::Repository->current_paths の結果
sub build {
    my ($class, $updates, $seed, $target_year, $current_paths) = @_;

    my $year = $seed // {};
    if ($seed) {
        # 対象年より前は git から再導出しないので seed をそのまま再注入する
        push @$updates, map { @{$year->{$_}->{modules}} } grep { $_ < $target_year } keys %$year;
        # 対象年以降は git から再導出するが、recent_data が列挙するのは現在の
        # checkout に実在するファイルだけなので、削除・rename された翻訳は
        # 再導出では拾えない。seed を残さないとその年の統計から恒久的に落ち、
        # しかも欠損したまま deploy.yml が master へ書き戻してしまう
        push @$updates, grep { not $current_paths->{$_->{path}} }
                        map  { @{$year->{$_}->{modules}} } grep { $_ >= $target_year } keys %$year;
    }

    # 全体を一度に並べ替える。「最初に現れた年に計上する」規則は下の reverse に
    # 依存しているので、ブロックを継ぎ足した順序に任せると後から push した分が
    # 先頭に来て古い年の実績を横取りする。path のタイブレークは同時刻エントリの
    # 順序を keys の列挙順に依存させないため
    @$updates = sort { $b->{date} cmp $a->{date} || $a->{path} cmp $b->{path} } @$updates;

    my %first;
    my %module;
    foreach my $module (reverse @$updates) {
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
