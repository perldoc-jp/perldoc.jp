use strict;
use warnings;
use utf8;

# GNU diff を外部コマンドとして使う vertical HTML diff。
# Text::Diff::FormattedHTML (純 Perl の Algorithm::Diff) の置き換え。
#
# 翻訳 POD は空行や =begin original などの同一行が数千回出現するため、
# Algorithm::Diff の LCS (同一行の出現位置ペアの総当たり) が最悪ケースに入り、
# perlfunc.pod 級 (~23,000 行) の比較は数十秒かかっていた。行の対応付けを
# GNU diff に任せることで同じ比較が 3 桁 ms になる。
#
# HTML の構造 (3 列の <tr>、match / disc_a del / disc_b ins / change del /
# change ins のクラス、文字単位の <del>/<ins>) は Text::Diff::FormattedHTML
# 0.08 の vertical 出力をそのまま踏襲しており、static/css/diff.css は無変更で
# 適用できる。変える場合は CSS との対応を必ず確認すること。
package PJP::HTMLDiff;

use Encode ();
use File::Temp ();
use Algorithm::Diff ();
use String::Diff ();

# c hunk 内の行の組み直し (sdiff) を行う hunk サイズの上限 (片側の行数)。
# GNU diff は連続する変更を 1 つの c hunk にまとめるため、hunk 内に埋もれた
# 同一行 (空行など) を LCS で match として回収するが、巨大 hunk で純 Perl の
# LCS に戻すと元の遅さが再発しうる。超えた場合は先頭から 1:1 で change ペアに
# する単純な対応付け (旧 traverse_balanced の CHANGE 規則と同じ) に落とす。
our $REFINE_LIMIT = 500;

# Text::Diff::FormattedHTML::diff_strings({vertical => 1}, $from, $to) 互換。
# 引数はデコード済み文字列 ($from が左 = del 側、$to が右 = ins 側)、
# 返り値は <table class='diff'> の HTML 断片 (デコード済み文字列)。
sub diff_strings_vertical {
    my ($from, $to) = @_;

    # split /\n/ は末尾の空行列を落とす (旧実装と同じ挙動)。一時ファイルには
    # この行配列を書き戻すことで、diff が報告する行番号と配列添字を必ず
    # 一致させる (元文字列をそのまま書くと末尾空行の分だけずれる)
    my @from_lines = split /\n/, $from;
    my @to_lines   = split /\n/, $to;

    my $hunks = _gnu_diff_hunks(\@from_lines, \@to_lines);
    return _render_vertical(\@from_lines, \@to_lines, $hunks);
}

# 2 つの行配列を GNU diff (normal format) にかけ、hunk コマンド行
# (XaY / X,YdZ / X,YcA,B) を [type, x1, x2, y1, y2] (1 始まり閉区間) の
# 配列にして返す。内容行は行番号から元の配列を引き直すので使わない。
sub _gnu_diff_hunks {
    my ($from_lines, $to_lines) = @_;

    my $from_file = _write_tempfile($from_lines);
    my $to_file   = _write_tempfile($to_lines);

    # LC_ALL=C で出力メッセージのロケール差を排除する。-a は制御文字が
    # 混ざった場合の "Binary files differ" を防ぎ、常に行単位の diff を強制。
    # パスは File::Temp 生成で安全だが、慣例に合わせ '--' で解釈を遮断する
    local $ENV{LC_ALL} = 'C';
    open my $fh, '-|', 'diff', '-a', '--', "$from_file", "$to_file"
        or die "Cannot run diff: $!";

    my @hunks;
    while (my $line = <$fh>) {
        chomp $line;
        if ($line =~ /\A(\d+)(?:,(\d+))?([adc])(\d+)(?:,(\d+))?\z/) {
            push @hunks, [$3, $1, $2 // $1, $4, $5 // $4];
        }
    }
    close $fh;

    # 終了コードは 0 = 差分なし, 1 = 差分あり, 2 以上 = 実行エラー
    my $exit = $? >> 8;
    die "diff exited with code $exit" if $exit >= 2;

    return \@hunks;
}

sub _write_tempfile {
    my ($lines) = @_;

    # TMPDIR 指定があればそれに従う (Cloud Run では未指定 = /tmp の tmpfs)。
    # オブジェクトの破棄で unlink されるため、呼び元は diff の実行が終わるまで
    # 返り値を保持すること
    my $tmp = File::Temp->new(TEMPLATE => 'pjp-htmldiff-XXXXXX', TMPDIR => 1, UNLINK => 1);
    binmode $tmp, ':raw';
    print {$tmp} Encode::encode_utf8(join('', map { "$_\n" } @$lines));
    close $tmp or die 'Cannot write ' . $tmp->filename . ": $!";
    return $tmp;
}

sub _render_vertical {
    my ($from_lines, $to_lines, $hunks) = @_;

    my ($ll, $rl);
    my $out = "<table class='diff'>\n";

    my $match = sub {
        my ($l, $r) = @_;
        ++$ll; ++$rl;
        $out .= _vertical_rows('match', $ll, $rl, _protect($l), _protect($r));
    };
    my $disc_a = sub {
        my ($l) = @_;
        ++$ll;
        $out .= _vertical_rows('disc_a', $ll, '', _protect($l), '');
    };
    my $disc_b = sub {
        my ($r) = @_;
        ++$rl;
        $out .= _vertical_rows('disc_b', '', $rl, '', _protect($r));
    };
    my $change = sub {
        my ($l, $r) = @_;
        my $diff = String::Diff::diff($l, $r,
            remove_open  => '#del#',
            remove_close => '#/del#',
            append_open  => '#ins#',
            append_close => '#/ins#',
        );
        ++$ll; ++$rl;
        $out .= _vertical_rows('change', $ll, $rl,
            _retag(_protect($diff->[0])), _retag(_protect($diff->[1])));
    };

    # c hunk の中身を出力する。上限内なら sdiff で組み直して hunk 内の同一行を
    # match として回収し、超過時は 1:1 の change ペア + 余りを disc にする
    my $change_block = sub {
        my ($a_lines, $b_lines) = @_;
        if (@$a_lines <= $REFINE_LIMIT && @$b_lines <= $REFINE_LIMIT) {
            for my $e (Algorithm::Diff::sdiff($a_lines, $b_lines)) {
                my ($op, $a, $b) = @$e;
                if    ($op eq 'u') { $match->($a, $b)  }
                elsif ($op eq 'c') { $change->($a, $b) }
                elsif ($op eq '-') { $disc_a->($a)     }
                else               { $disc_b->($b)     }
            }
        } else {
            my $n = @$a_lines < @$b_lines ? scalar @$a_lines : scalar @$b_lines;
            $change->($a_lines->[$_], $b_lines->[$_]) for 0 .. $n - 1;
            $disc_a->($a_lines->[$_]) for $n .. $#{$a_lines};
            $disc_b->($b_lines->[$_]) for $n .. $#{$b_lines};
        }
    };

    my $i = 0;    # 消費済みの from 行数 (= 次に読む 0 始まり添字)
    my $j = 0;    # 消費済みの to 行数
    my $sync_to = sub {
        # from の $x 行目 (1 始まり) まで、両側を match として消費する
        my ($x) = @_;
        while ($i < $x) {
            $match->($from_lines->[$i], $to_lines->[$j]);
            $i++; $j++;
        }
    };

    for my $hunk (@$hunks) {
        my ($type, $x1, $x2, $y1, $y2) = @$hunk;
        if ($type eq 'a') {
            # XaY,Z: from の X 行目までは共通で、その直後に to の Y..Z 行が挿入
            $sync_to->($x1);
            $disc_b->($to_lines->[$_ - 1]) for $y1 .. $y2;
            $j = $y2;
        } elsif ($type eq 'd') {
            # X,YdZ: from の X-1 行目までは共通で、X..Y 行が削除
            $sync_to->($x1 - 1);
            $disc_a->($from_lines->[$_ - 1]) for $x1 .. $x2;
            $i = $x2;
        } else {    # 'c'
            # X,YcA,B: from の X..Y 行が to の A..B 行に変更
            $sync_to->($x1 - 1);
            $change_block->(
                [@{$from_lines}[$x1 - 1 .. $x2 - 1]],
                [@{$to_lines}[$y1 - 1 .. $y2 - 1]],
            );
            $i = $x2;
            $j = $y2;
        }
    }
    $sync_to->(scalar @$from_lines);    # 最後の hunk 以降は全て共通

    $out .= "</table>\n";
    return $out;
}

# 以下 3 つは Text::Diff::FormattedHTML 0.08 の vertical 出力の忠実な移植。
# 出力の互換性 (行の形・クラス名・エスケープ) を守るため、独自の改変は
# 加えないこと。

sub _vertical_rows {
    my ($class, $ln, $rn, $l, $r) = @_;
    my $out = '';
    if ($l eq $r) {
        $out .= sprintf("<tr class='%s'><td>%s</td><td>%s</td><td>%s</td></tr>\n",
                        $class, $ln, $rn, $l);
    } else {
        $class eq 'disc_a' && ($class = 'disc_a del');
        $class eq 'disc_b' && ($class = 'disc_b ins');

        $class eq 'change' && ($class = 'change del');
        $l and $out .= sprintf("<tr class='%s'><td>%s</td><td></td><td>%s</td></tr>\n",
                               $class, $ln, $l);
        $class eq 'change del' && ($class = 'change ins');
        $r and $out .= sprintf("<tr class='%s'><td></td><td>%s</td><td>%s</td></tr>\n",
                               $class, $rn, $r);
    }
    return $out;
}

sub _protect {
    my $x = shift;
    if ($x) {
        $x =~ s/&/&amp;/g;
        $x =~ s/</&lt;/g;
        $x =~ s/>/&gt;/g;
    }
    return $x;
}

sub _retag {
    my $x = shift;
    $x =~ s{#(.?(?:del|ins))#}{<$1>}g;
    return $x;
}

1;
