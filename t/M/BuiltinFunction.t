use v5.38;
use utf8;
use Test2::V0;

use Cwd ();
use File::Temp qw/tempdir/;
use PJP::M::BuiltinFunction;

# functions.txt は generate が書く生成物なので、クリーンビルドではモジュール
# ロード時に存在しない。ロード時に一度きりで確定させると、同一プロセスで後から
# 走る PodFile->generate が空の @REGEXP を使い、perlfunc の HTML から
# 組み込み関数へのリンクが黙って消える (イメージにだけ焼き込まれ、テストは
# functions.txt が既にある状態で走るので気づけない)。
#
# ここでは generate 全体は回さず、「一覧を書いた後に読み直せば @REGEXP が
# 埋まる」という _load_functions の契約だけを検証する。

# PodFile.pm:196-198 が perlfunc の HTML に対してやっていることと同じ置換
sub link_functions {
    my $html = shift;
    foreach my $regexp (@PJP::M::BuiltinFunction::REGEXP) {
        $html =~ s{<code>($regexp)</code>}{<code><a href="/func/$1" target="_blank">$1</a></code>}g;
    }
    return $html;
}

my $orig_cwd = Cwd::getcwd();
my $tmp      = tempdir(CLEANUP => 1);
chdir $tmp or die $!;

subtest 'functions.txt が無ければ @REGEXP は空' => sub {
    ok !-e 'functions.txt', 'functions.txt が無い状態';
    PJP::M::BuiltinFunction::_load_functions();
    is scalar(@PJP::M::BuiltinFunction::REGEXP), 0, '@REGEXP が空';
    is scalar(@PJP::M::BuiltinFunction::FUNCTIONS), 0, '@FUNCTIONS が空';
    is link_functions('<code>print</code>'), '<code>print</code>', 'リンクにならない';
};

subtest '一覧を書いて読み直すと @REGEXP が埋まる' => sub {
    open my $fh, '>', 'functions.txt' or die $!;
    print $fh join "\n", qw/chomp chop print printf say sprintf/;
    close $fh;

    PJP::M::BuiltinFunction::_load_functions();
    is scalar(@PJP::M::BuiltinFunction::FUNCTIONS), 6, '@FUNCTIONS が読み込まれる';
    ok scalar(@PJP::M::BuiltinFunction::REGEXP) > 0, '@REGEXP が構築される';
    is link_functions('<code>print</code>'),
        '<code><a href="/func/print" target="_blank">print</a></code>',
        'perlfunc の関数名がリンクになる';
};

subtest '読み直しは前回の内容を持ち越さない' => sub {
    unlink 'functions.txt' or die $!;
    PJP::M::BuiltinFunction::_load_functions();
    is scalar(@PJP::M::BuiltinFunction::REGEXP), 0, '@REGEXP がクリアされる';
    ok !PJP::M::BuiltinFunction->exists('print'), '%FUNCTIONS もクリアされる';
};

chdir $orig_cwd or die $!;

# リポジトリの functions.txt を読み直して、後続のテストに影響を残さない
PJP::M::BuiltinFunction::_load_functions();

done_testing;
