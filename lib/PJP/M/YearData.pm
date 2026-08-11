use strict;
use warnings;
use utf8;

package PJP::M::YearData;
use PJP::M::Repository ();

# data/years.pl の中身を組み立てる。ファイル入出力は script/create_data.pl
# 側に残し、ここは (翻訳イベント列, seed, 対象年) から年ごとの統計を作る
# 純粋な処理だけを持つ。
#
# $events      : PJP::M::Repository->commit_events の結果 (git log の走査順 =
#                配列の先頭側が新しい)。削除・rename で現ツリーから消えた
#                翻訳のイベントも含む
# $seed        : 既存の data/years.pl を読んだもの。初回ビルドでは undef。
#                対象年より前の年だけが取り込まれ、対象年以降のキーは無視される
# $target_year : 再導出の対象年 (= 前年)。これ以降が git 由来で組み直される

# git 履歴から再導出できる最古の年。これより前の統計は、複数の旧リポジトリを
# 当時のシステムで観測した結果の凍結で、現在の git 履歴からは再現できない
use constant GIT_DERIVABLE_SINCE => 2011;

# data/years.pl が持つ最も古い年。この年から対象年の前年までが揃っていない
# seed は、途中の年が失われた状態なので受け付けない
use constant SEED_SINCE => 2002;

sub build {
    my ($class, $events, $seed, $target_year) = @_;

    # 対象年より前の seed は取り込むだけで再検証されないため、再導出できない
    # 年を対象にすると凍結された統計を不完全な導出結果で黙って置き換えて
    # しまう。docs/cloud-run.md が回復手順として対象年の手動指定
    # (script/create_data.pl <対象年>) を案内しているので、誤指定はここで止める
    die "target year must be a 4-digit year (got: " . ($target_year // 'undef') . ")\n"
        unless defined $target_year && $target_year =~ /^[0-9]{4}$/;
    die "target year $target_year predates git-derivable history:"
        . " years before @{[ GIT_DERIVABLE_SINCE ]} are frozen observations"
        . " that cannot be rebuilt from the git history\n"
        if $target_year < GIT_DERIVABLE_SINCE;

    # 最新イベントより後の年を対象にすると、全イベントが対象年より前として
    # 捨てられ、seed をそのまま書き戻しただけの結果が正常終了する。回復手順の
    # 打ち間違いが「差分が出ない = 再導出は不要だった」と読めてしまうため止める
    my ($newest_year) = sort { $b <=> $a } map { $_->{date} =~ m{^(\d{4})} } @$events;
    die "target year $target_year is after the newest translation event ($newest_year);"
        . " nothing would be rebuilt\n"
        if defined $newest_year && $target_year > $newest_year;

    # 再利用するブロック (対象年より前) だけ形を検査する。対象年以降は毎回
    # 捨てて作り直すので、壊れていても結果に影響しない
    _assert_seed_block($_, $seed->{$_}) for grep { $_ < $target_year } keys %{ $seed // {} };

    # 対象年以降を「path ごとの年内最終イベント」に畳む。イベント列は git の
    # 走査順 (新しい方が先) なので、(年, path) の初出が年内最終。年内最終が
    # 削除の path はその年に数えない。旧 VPS が毎日の観測で当年を上書きし
    # 年末時点の状態を凍結していたのと同じ意味論になる (年の途中の削除は
    # その年から消え、削除前の年の実績はイベントがある限り残る)
    my %latest;
    foreach my $event (@$events) {
        my ($y) = $event->{date} =~ m{^(\d+)} or next;
        next if $y < $target_year;
        $latest{$y}{$event->{path}} //= $event;
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
            : $module{_dedup_in($module->{in})}->{$module->{version}}++;
        if (not $n) {
            push @{$year->{$y}->{modules}}, $module;
            $year->{$y}->{commit_count}->{$module->{author}}++;
        }
        if ($y >= $target_year) {
            $year->{$y}->{commit_count_all}->{$module->{author}}++;
        }
    }

    # 対象年より前の年が縮んでいたら返さない (年ブロック自体は上の 1 段コピーで
    # 必ず残る)。seed 由来の年も再構築ループ (重複排除) を通るため、キーの
    # 解釈の誤り等で seed 済みのエントリが食われる余地があり、結果は自動
    # コミットで次回ビルドの seed になって誤りが恒久化する。seed のどの年が
    # 保存対象かを知るのはこのモジュールなので、検査もここで行う
    if ($seed) {
        for my $y (grep { $_ < $target_year } keys %$seed) {
            die "year $y lost modules in rebuild"
                if @{$year->{$y}{modules}} != @{$seed->{$y}{modules}};
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

# data/years.pl が原本として欠けていないことを検査する。
#
# build は与えられた seed の形しか見ない (純粋な組み立てなので、どの年が
# 揃っているべきかは入力の性質)。実際の data/years.pl は 2002 年から連続して
# いて、2011 年より前は git 履歴から再現できない唯一の原本なので、欠けた
# ファイルを黙って通すと復元できないまま自動コミットで上書きされる。
# その前提を知っているのは呼び出し側 (databuild) なので、検査もそこから呼ぶ。
sub assert_seed_is_complete {
    my ($class, $seed, $target_year) = @_;

    die "no seed given; data/years.pl holds the only copy of the pre-"
        . GIT_DERIVABLE_SINCE . " statistics (restore it with: git restore data/years.pl)\n"
        unless $seed && %$seed;

    my $this_year = PJP::M::Repository->_now_jst()->year;
    my @bad_keys = sort grep { !/^[0-9]{4}$/ || $_ < SEED_SINCE || $_ > $this_year } keys %$seed;
    die "data/years.pl has keys that are not plausible years:\n"
        . join('', map { "  $_\n" } @bad_keys)
        if @bad_keys;

    my @missing = grep { !exists $seed->{$_} } SEED_SINCE .. $target_year - 1;
    die "data/years.pl is missing these years:\n"
        . join('', map { "  $_\n" } @missing)
        . "years before @{[ GIT_DERIVABLE_SINCE ]} cannot be rebuilt from the git history\n"
        if @missing;
    return;
}

# 再利用する年ブロックの形を検査する。build がそのまま次の data/years.pl へ
# 引き継ぐので、壊れた値はここで止めないと自動コミットで恒久化する
sub _assert_seed_block {
    my ($y, $block) = @_;

    my $bad = sub { die "data/years.pl year $y is broken: $_[0]\n" };

    $bad->('not a hash') if ref $block ne 'HASH';
    # modules は空でもよい。更新はあったが、その年に初出となる dist が
    # 無かった年を build 自身が modules => [] で作る
    $bad->('modules is not an array') if ref $block->{modules} ne 'ARRAY';
    for my $module (@{$block->{modules}}) {
        $bad->('a module entry is not a hash') if ref $module ne 'HASH';
        for my $field (qw/date author path name in version/) {
            # 参照が入っていると Data::Dumper では書き戻せてしまい、表示側で
            # 初めて壊れる。値として使える形かまで見る
            $bad->("a module entry has a broken $field")
                if !defined $module->{$field} || ref $module->{$field};
        }
    }

    $bad->('commit_count_all is not a hash') if ref $block->{commit_count_all} ne 'HASH';
    $bad->('commit_count_all is empty')      if !%{$block->{commit_count_all}};
    $bad->('commit_count is not an array')   if ref $block->{commit_count} ne 'ARRAY';

    my %seen;
    for my $row (@{$block->{commit_count}}) {
        $bad->('a commit_count row is not an array') if ref $row ne 'ARRAY' || @$row != 3;
        my ($author, $all, $first) = @$row;
        $bad->('a commit_count row has no author')
            unless defined $author && !ref $author && length $author;
        $bad->("commit_count has $author twice")   if $seen{$author}++;
        $bad->("$author is not in commit_count_all") unless exists $block->{commit_count_all}{$author};
        # 件数は数を数えたものなので非負整数しかありえない。数値比較だけだと
        # 双方が同じ負数や小数でも通ってしまう
        $bad->("$author has a broken count") unless _is_count($all);
        $bad->("$author has a broken count in commit_count_all")
            unless _is_count($block->{commit_count_all}{$author});
        $bad->("$author has a different count in commit_count_all")
            if $all != $block->{commit_count_all}{$author};
        # 3 番目は「その年に初出だった dist の数」で、0 件の author は undef の
        # まま出力される (既存の data/years.pl にも実在する)
        $bad->("$author has a broken first-appearance count")
            if defined $first && !_is_count($first);
    }
    $bad->('commit_count and commit_count_all disagree on the set of authors')
        if keys %seen != keys %{$block->{commit_count_all}};
    return;
}

sub _is_count {
    my ($n) = @_;
    return defined $n && !ref $n && $n =~ /^[0-9]+$/;
}

# 「同じ dist の同じ版か」の判定に使う in の正規化。in は表示用の文字列で、
# モジュール名の導出規則が「先頭のハイフン 1 個だけ ::」から「全ハイフン」に
# 変わった経緯があり、seed には旧規則の値 (例: Class::Data-Inheritable) が
# 凍結されている。表示は凍結のまま、同一性だけを現行規則へ冪等に収束させ、
# 同じ dist の同じ版が seed と新イベントで別物として二重計上されるのを防ぐ
sub _dedup_in {
    my ($in) = @_;
    $in =~ s{-}{::}g;
    return $in;
}

1;
