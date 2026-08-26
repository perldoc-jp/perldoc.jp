use v5.38;
use utf8;
use Test2::V0;

use File::Temp qw/tempdir/;
use File::Spec;
use PJP::M::BuiltinFunction;

# functions.txt は generate が書く生成物なので、クリーンビルドではモジュール
# ロード時に存在しない。ロード時に一度きりで確定させると、同一プロセスで後から
# 走る PodFile->generate が空の @REGEXP を使い、perlfunc の HTML から
# 組み込み関数へのリンクが黙って消える (イメージにだけ焼き込まれ、テストは
# functions.txt が既にある状態で走るので気づけない)。
#
# generate 全体は DB と perlfunc.pod を要るので回さず、「一覧を書いた後に
# 読み直せば @REGEXP が埋まる」という _load_functions の契約だけを検証する。
# リンク付与は PodFile が呼ぶ linkify_functions をそのまま使う (テスト側で
# 置換を書き写すと、実装が変わったときに壊れずに嘘のまま通ってしまう)。

# _load_functions はパッケージ変数を書き換えるので、local で退避してから呼ぶ。
# 読み込み元は引数で差し替えられるので cwd には触らない。
sub with_functions_txt {
    my ($contents, $cb) = @_;
    my $file = File::Spec->catfile(tempdir(CLEANUP => 1), 'functions.txt');
    if (defined $contents) {
        open my $fh, '>', $file or die $!;
        print $fh $contents;
        close $fh;
    }
    local (@PJP::M::BuiltinFunction::FUNCTIONS,
           %PJP::M::BuiltinFunction::FUNCTIONS,
           @PJP::M::BuiltinFunction::REGEXP);
    PJP::M::BuiltinFunction::_load_functions($file);
    $cb->();
}

my @LOADED_AT_START = @PJP::M::BuiltinFunction::FUNCTIONS;

subtest 'functions.txt が無ければ @REGEXP は空' => sub {
    with_functions_txt undef, sub {
        is scalar(@PJP::M::BuiltinFunction::REGEXP),    0, '@REGEXP が空';
        is scalar(@PJP::M::BuiltinFunction::FUNCTIONS), 0, '@FUNCTIONS が空';
        is PJP::M::BuiltinFunction->linkify_functions('<code>print</code>'),
            '<code>print</code>', '関数名がリンクにならない';
    };
};

subtest '一覧を書いて読み直すと @REGEXP が埋まる' => sub {
    with_functions_txt join("\n", qw/chomp chop print printf say sprintf/), sub {
        is scalar(@PJP::M::BuiltinFunction::FUNCTIONS), 6, '@FUNCTIONS が読み込まれる';
        ok scalar(@PJP::M::BuiltinFunction::REGEXP) > 0, '@REGEXP が構築される';
        is PJP::M::BuiltinFunction->linkify_functions('<code>print</code>'),
            '<code><a href="/func/print" target="_blank">print</a></code>',
            'perlfunc の関数名がリンクになる';
        ok PJP::M::BuiltinFunction->exists('print'), '%FUNCTIONS も更新される';
    };
};

subtest '読み直しは前回の内容を持ち越さない' => sub {
    with_functions_txt "chomp\nchop", sub {
        ok PJP::M::BuiltinFunction->exists('chomp'), '書いた分は見える';
        ok !PJP::M::BuiltinFunction->exists('print'), '前のサブテストの分は残らない';
    };
};

subtest 'クォート系演算子は functions.txt に依らずリンクになる' => sub {
    # linkify_functions の 2 番目の置換は @REGEXP を使わないので、
    # functions.txt が空でも効く (欠落時に 9 件だけ残るのはこの分)
    with_functions_txt undef, sub {
        is PJP::M::BuiltinFunction->linkify_functions('<code>qw//</code>'),
            '<code><a href="/func/qw" target="_blank">qw//</a></code>',
            'qw// がリンクになる';
    };
};

subtest 'local を抜けたらグローバルな状態が復元される' => sub {
    is \@PJP::M::BuiltinFunction::FUNCTIONS, \@LOADED_AT_START,
        'サブテストの前後で @FUNCTIONS が変わっていない';
};

done_testing;
