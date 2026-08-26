use v5.38;
use utf8;
use Test2::V0;

use English ();
use File::Temp qw/tempdir/;
use PJP::M::BuiltinVariable;

# 候補列を組むときに @English::COMPLETE_EXPORT を壊さないこと。
# map の $_ は配列要素のエイリアスなので、コピーせずに置換すると
# English の export 一覧から '*' が消え、同じプロセスで English を
# 使う後続のコードが壊れる。
#
# 要素数だけを見ても検出できない ('*FOO' が 'FOO' になるだけで数は変わらない)
# ので、中身を deep comparison で見る

my $dir = tempdir(CLEANUP => 1);

sub write_pod {
    my ($name, @lines) = @_;
    my $path = "$dir/$name";
    open my $fh, '>', $path or die "Cannot open $path: $!";
    print {$fh} "$_\n" for @lines;
    close $fh;
    return $path;
}

subtest '@English::COMPLETE_EXPORT を壊さない' => sub {
    my $path = write_pod('perlvar.pod', '=encoding utf-8', '', 'X<$FOO>');
    my @before = @English::COMPLETE_EXPORT;

    my @first  = PJP::M::BuiltinVariable::_candidates($path);
    is \@English::COMPLETE_EXPORT, \@before, '呼び出しの前後で export 一覧が同一';

    my @second = PJP::M::BuiltinVariable::_candidates($path);
    is \@second, \@first, '2 回目も同じ候補列を返す (冪等)';
    is \@English::COMPLETE_EXPORT, \@before, '2 回呼んでも export 一覧が同一';
};

subtest '候補列の組み立て' => sub {
    # 実物の @English::COMPLETE_EXPORT は 50 件を超えるので、
    # 期待値を完全一致で書けるように小さく差し替える
    local @English::COMPLETE_EXPORT = ('*FOO', 'BAR', '*FOO');
    # X<< ... >> は X<...> の正規表現にも当たり '< @QUUX ' のような候補も
    # 生む (元の実装からの挙動)。ここで見たいのは * の展開と重複除去なので、
    # fixture は X<...> だけにする
    my $path = write_pod(
        'small.pod',
        '=encoding utf-8',
        '',
        'X<$BAZ> and X<@QUUX>',
        'X<$BAZ> appears twice',
    );

    is [PJP::M::BuiltinVariable::_candidates($path)],
       [sort qw/$FOO %FOO @FOO BAR $BAZ @QUUX/],
       '* 付きは $ % @ の 3 つに展開され、X<> と混ぜて重複を除き整列される';

    is \@English::COMPLETE_EXPORT, ['*FOO', 'BAR', '*FOO'],
       'local した配列も壊れない';
};

subtest '_encoding_of' => sub {
    is PJP::M::BuiltinVariable::_encoding_of(
           write_pod('enc.pod', '=head1 NAME', '', '=encoding euc-jp', '', '=encoding utf-8')),
       'euc-jp', '最初の =encoding を採る';

    is PJP::M::BuiltinVariable::_encoding_of(write_pod('noenc.pod', '=head1 NAME')),
       undef, '宣言が無ければ undef';
};

done_testing;
