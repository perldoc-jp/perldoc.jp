use v5.38;
use utf8;
use Test2::V0;

use File::Temp qw/tempdir/;
use PJP::HTMLDiff;

# 正常な hunk を 1 つ出力してから指定の死に方をする diff ラッパを作り、
# その置き場所を返す。呼び出し側が PATH の先頭に差し込む
sub fake_diff_bin {
    my ($tail) = @_;
    my $bin = tempdir(CLEANUP => 1);
    open my $fh, '>', "$bin/diff" or die $!;
    print $fh "#!/bin/sh\n";
    print $fh "echo '2c2'\n";
    print $fh "$tail\n";
    close $fh;
    chmod 0755, "$bin/diff" or die $!;
    return $bin;
}

subtest '同一入力なら全行 match になる' => sub {
    my $html = PJP::HTMLDiff::diff_strings_vertical("a\nb\nc\n", "a\nb\nc\n");
    like $html, qr{\A<table class='diff'>\n}, 'table で始まる';
    like $html, qr{</table>\n\z},             'table で終わる';
    is scalar(() = $html =~ m{<tr }g), 3, '行数分の tr がある';
    unlike $html, qr{class='(?:change|disc_a|disc_b)}, 'match 以外の行がない';
    like $html, qr{<tr class='match'><td>1</td><td>1</td><td>a</td></tr>}, '行番号と内容が出る';
    like $html, qr{<tr class='match'><td>3</td><td>3</td><td>c</td></tr>}, '最終行まで出る';
};

subtest '追加行は disc_b ins になる' => sub {
    my $html = PJP::HTMLDiff::diff_strings_vertical("a\nc\n", "a\nb\nc\n");
    like $html, qr{<tr class='match'><td>1</td><td>1</td><td>a</td></tr>},    '前の共通行';
    like $html, qr{<tr class='disc_b ins'><td></td><td>2</td><td>b</td></tr>}, '追加行';
    like $html, qr{<tr class='match'><td>2</td><td>3</td><td>c</td></tr>},    '後の共通行 (行番号がずれて追従)';
};

subtest '削除行は disc_a del になる' => sub {
    my $html = PJP::HTMLDiff::diff_strings_vertical("a\nb\nc\n", "a\nc\n");
    like $html, qr{<tr class='disc_a del'><td>2</td><td></td><td>b</td></tr>}, '削除行';
    like $html, qr{<tr class='match'><td>3</td><td>2</td><td>c</td></tr>},     '後の共通行';
};

subtest '変更行は change del/ins になり文字単位の <del>/<ins> が付く' => sub {
    my $html = PJP::HTMLDiff::diff_strings_vertical("hello world\n", "hello perl\n");
    like $html, qr{<tr class='change del'><td>1</td><td></td><td>hello [^<]*<del>[^<]*</del>}, '変更前の行に <del>';
    like $html, qr{<tr class='change ins'><td></td><td>1</td><td>hello [^<]*<ins>[^<]*</ins>}, '変更後の行に <ins>';
};

subtest 'HTML特殊文字はエスケープされる' => sub {
    my $html = PJP::HTMLDiff::diff_strings_vertical("1 < 2 & <b>\n", "1 < 2 & <i>\n");
    like $html,   qr{&lt;},  '< がエスケープされる';
    like $html,   qr{&amp;}, '& がエスケープされる';
    unlike $html, qr{<b>},   '生のタグが混入しない';
};

subtest 'マルチバイト文字列が壊れない' => sub {
    my $html = PJP::HTMLDiff::diff_strings_vertical("こんにちは世界\n共通行\n", "こんにちはPerl\n共通行\n");
    like $html, qr{こんにちは},                                            '内容が保持される';
    like $html, qr{<tr class='match'><td>2</td><td>2</td><td>共通行</td>}, '共通行は match';
    like $html, qr{<del>},                                                 '変更部分に <del>';
};

subtest '空文字列との比較' => sub {
    my $html = PJP::HTMLDiff::diff_strings_vertical('', "a\nb\n");
    like $html, qr{<tr class='disc_b ins'><td></td><td>1</td><td>a</td></tr>}, '全行が追加になる';
    is scalar(() = $html =~ m{<tr }g), 2, '2 行分の tr';

    my $empty = PJP::HTMLDiff::diff_strings_vertical('', '');
    is $empty, "<table class='diff'>\n</table>\n", '両方空なら空の table';
};

subtest '内容が "0" だけの行も増減が描画される' => sub {
    # "0" は Perl の真偽値判定で偽になるため、移植元 Text::Diff::FormattedHTML は
    # この行の増減を丸ごと落とす。行が黙って消えると差分の見落としになるので、
    # 旧実装との唯一の意図的な差分として修正を固定する (このリポジトリは
    # falsy な "0" を defined/length で扱う)
    my $del = PJP::HTMLDiff::diff_strings_vertical("a\n0\nb\n", "a\nb\n");
    like $del, qr{<tr class='disc_a del'><td>2</td><td></td><td>0</td></tr>}, '"0" の削除行が出る';

    my $ins = PJP::HTMLDiff::diff_strings_vertical("a\nb\n", "a\n0\nb\n");
    like $ins, qr{<tr class='disc_b ins'><td></td><td>2</td><td>0</td></tr>}, '"0" の追加行が出る';
};

subtest '変更行の片側が "0" でも内容が残る' => sub {
    # String::Diff は文字列が偽なら区間を 1 つも返さないため、"0" の側が
    # 変更行から丸ごと消えていた (増減の行ではなく、変更として組になる場合)
    my %cases = (
        '"0" が空行に変わる'   => ["a\n0\nz\n", "a\n\nz\n",   qr{<del>0</del>}],
        '空行が "0" に変わる'  => ["a\n\nz\n",  "a\n0\nz\n",  qr{<ins>0</ins>}],
        '"0" が "x" に変わる'  => ["a\n0\nz\n", "a\nx\nz\n",  qr{<del>0</del>}],
        '"x" が "0" に変わる'  => ["a\nx\nz\n", "a\n0\nz\n",  qr{<ins>0</ins>}],
        '"0" が "00" に変わる' => ["a\n0\nz\n", "a\n00\nz\n", qr{<del>0</del>}],
    );
    for my $name (sort keys %cases) {
        my ($from, $to, $expected) = @{ $cases{$name} };
        like PJP::HTMLDiff::diff_strings_vertical($from, $to), $expected, $name;
    }
};

subtest 'HTML のメタ文字が変更行でもエスケープされる' => sub {
    # 変更部分は <del>/<ins> で囲むので、本文側のエスケープが抜けると
    # 翻訳に含まれる山括弧がそのままタグとして解釈される
    # 変更部分は <del>/<ins> で割られるため、実体参照も分断されて出る
    my $html = PJP::HTMLDiff::diff_strings_vertical("x\n<a> & 'b'\ny\n", "x\n<c> & 'd'\ny\n");
    like $html,   qr{&lt;<del>a</del>&gt;}, '< と > が実体参照になる (変更部分を挟んでも)';
    like $html,   qr{&amp;},                '& が実体参照になる';
    unlike $html, qr{(?<!&lt;)<a>},         '生の <a> が出ない';
};

subtest 'REFINE_LIMIT 超過時に内容が同じ行を変更として壊さない' => sub {
    # 上限を超えると sdiff を使わず 1:1 で組にするので、たまたま同じ内容の
    # 行どうしが組になる。falsy な "0" でも内容を落とさない
    local $PJP::HTMLDiff::REFINE_LIMIT = 1;
    my $html = PJP::HTMLDiff::_render_vertical(['0', 'a'], ['0', 'b'], [['c', 1, 2, 1, 2]]);
    like $html, qr{<tr class='change'><td>1</td><td>1</td><td>0</td></tr>},
        '左右が同じ "0" は change の 1 行として残る';
    unlike $html, qr{<del>0</del>|<ins>0</ins>}, '同じ内容なので del/ins に割らない';
    like $html, qr{<tr class='change del'><td>2</td><td></td><td><del>a</del></td></tr>},
        '本当に変わった行はこれまでどおり割る';
};

subtest '本文に含まれる #del# が偽のタグにならない' => sub {
    # 旧実装は #del# 等を本文に埋め込んでから置換していたため、同じ文字列を
    # 含む翻訳の差分でリテラルが消えて表示が壊れた
    my $html = PJP::HTMLDiff::diff_strings_vertical("x\n#del# a\ny\n", "x\n#del# b\ny\n");
    like $html, qr{<tr class='change del'><td>2</td><td></td><td>\#del\# <del>a</del></td></tr>},
        'リテラルはそのまま残り、実際の変更部分だけがタグになる';
    like $html, qr{<tr class='change ins'><td></td><td>2</td><td>\#del\# <ins>b</ins></td></tr>},
        '右側も同じ';
};

subtest '末尾改行がなくても同じ結果になる' => sub {
    is(
        PJP::HTMLDiff::diff_strings_vertical("a\nb", "a\nc"),
        PJP::HTMLDiff::diff_strings_vertical("a\nb\n", "a\nc\n"),
        '末尾改行の有無で出力が変わらない',
    );
};

# GNU diff は連続する変更を 1 つの c hunk にまとめることがあるため、hunk の
# 中身の展開は _render_vertical に合成 hunk を渡して直接検証する (実際の
# diff コマンドがどう hunk を切るかに依存しない)
subtest 'c hunk 内の組み直し' => sub {
    my @from = ('x1', 'same', 'x2');
    my @to   = ('y1', 'same', 'y2');
    my $hunks = [['c', 1, 3, 1, 3]];

    subtest 'sdiff で hunk 内の同一行を match として回収する' => sub {
        my $html = PJP::HTMLDiff::_render_vertical(\@from, \@to, $hunks);
        like $html, qr{<tr class='match'><td>2</td><td>2</td><td>same</td></tr>}, '埋もれた同一行が match になる';
        like $html, qr{<tr class='change del'><td>1</td><td></td><td>[^<]*<del>}, '前後は change のまま';
    };

    subtest 'REFINE_LIMIT 超過時は 1:1 の change ペアに落ちる' => sub {
        local $PJP::HTMLDiff::REFINE_LIMIT = 1;
        my $html = PJP::HTMLDiff::_render_vertical(\@from, \@to, $hunks);
        # 1:1 ペアで同一内容が change に渡ると、両辺が等しいため単一行になる
        like $html, qr{<tr class='change'><td>2</td><td>2</td><td>same</td></tr>}, '同一行も change として 1:1 対応する';
    };

    subtest 'REFINE_LIMIT 超過時の行数不一致は余りが disc になる' => sub {
        local $PJP::HTMLDiff::REFINE_LIMIT = 1;
        my $html = PJP::HTMLDiff::_render_vertical(['a1', 'a2', 'a3'], ['b1'], [['c', 1, 3, 1, 1]]);
        like $html, qr{<tr class='disc_a del'><td>2</td><td></td><td>a2</td></tr>}, '余った from 行は disc_a';
        like $html, qr{<tr class='disc_a del'><td>3</td><td></td><td>a3</td></tr>}, '余りは全て出る';
    };
};

subtest '外部 diff の異常終了を差分なしとして描画しない' => sub {
    # 途中で死んだ diff の部分的な hunk 列をそのまま描画すると、最後の hunk 以降の
    # 相違行がすべて match 行になった「差分がほぼ無い」ページが 200 で返る。
    # 黙って嘘を表示するより、エラーとして扱わなければならない

    subtest 'シグナル死' => sub {
        # $? >> 8 は 0 になるため、終了コードだけを見ていると成功と区別が付かない
        my $bin = fake_diff_bin('kill -9 $$');
        local $ENV{PATH} = "$bin:$ENV{PATH}";
        like dies { PJP::HTMLDiff::diff_strings_vertical("a\nb\nc\n", "a\nx\nc\n") },
            qr/killed by signal 9/, 'die する';
    };

    subtest '実行エラー (終了コード 2 以上)' => sub {
        my $bin = fake_diff_bin('exit 2');
        local $ENV{PATH} = "$bin:$ENV{PATH}";
        like dies { PJP::HTMLDiff::diff_strings_vertical("a\nb\nc\n", "a\nx\nc\n") },
            qr/exited with status 2/, 'die する';
    };

    subtest '差分あり (終了コード 1) は正常', sub {
        # diff(1) は差分があると 1 を返す。これをエラーにすると全ての差分表示が
        # 落ちるので、正常扱いのままであることを固定する
        my $html = PJP::HTMLDiff::diff_strings_vertical("a\nb\n", "a\nc\n");
        like $html, qr{<tr class='change del'}, '差分が描画される';
    };
};

# 旧実装 Text::Diff::FormattedHTML がインストールされている間は、LCS の
# 解が一意になる入力で出力がバイト一致することを検証する (cpanfile からは
# 外したので、snapshot 再生成後はスキップされる)
subtest '旧実装 Text::Diff::FormattedHTML との互換性' => sub {
    skip_all 'Text::Diff::FormattedHTML がインストールされていない'
        unless eval { require Text::Diff::FormattedHTML; 1 };

    my @cases = (
        ['同一',     "a\nb\nc\n",       "a\nb\nc\n"],
        ['純追加',   "a\nd\n",          "a\nb\nc\nd\n"],
        ['純削除',   "a\nb\nc\nd\n",    "a\nd\n"],
        ['単一変更', "a\nb\nc\n",       "a\nX\nc\n"],
        ['先頭追加', "b\n",             "a\nb\n"],
        ['末尾削除', "a\nb\n",          "a\n"],
        ['空 vs 有', '',                "a\n"],
        ['複数箇所', "a\nb\nc\nd\ne\n", "a\nX\nc\nY\ne\n"],
    );
    for my $case (@cases) {
        my ($name, $from, $to) = @$case;
        is(
            PJP::HTMLDiff::diff_strings_vertical($from, $to),
            Text::Diff::FormattedHTML::diff_strings({vertical => 1}, $from, $to),
            "$name: 旧実装とバイト一致",
        );
    }
};

done_testing;
