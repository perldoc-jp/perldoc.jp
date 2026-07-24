use v5.38;
use utf8;
use Test2::V0;

use PJP::HTMLDiff;

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
