use v5.38;
use utf8;
use Test2::V0;

use Cwd ();
use Encode ();
use File::Temp qw/tempdir/;
use JSON::XS ();
use XML::RSS;

# 生成側 (script/create_data.pl) の書き出しをそのまま呼ぶ。テスト側で
# エンコードのやり方を書き写すと、生成側の指定を消しても通ってしまう
require './script/create_data.pl';

# 生成物は cwd からの相対パスに書かれるので、使い捨てのディレクトリへ移る
sub in_tempdir {
    my ($cb) = @_;
    my $orig = Cwd::getcwd();
    my $dir  = tempdir(CLEANUP => 1);
    chdir $dir or die $!;
    my $guard = Guard->new(sub { chdir $orig or die $! });
    mkdir 'static' or die $!;
    mkdir 'static/rss' or die $!;
    $cb->($dir);
}

{
    package Guard;
    sub new { my ($class, $cb) = @_; bless { cb => $cb }, $class }
    sub DESTROY { $_[0]->{cb}->() }
}

sub slurp_bytes {
    open my $fh, '<:raw', $_[0] or die "$_[0]: $!";
    return do { local $/; <$fh> };
}

# create_docs_json が引くのは package の一覧と get_latest だけなので、
# その 2 つを返す最小のダブルを渡す
{
    package Test::Pjp;
    sub new  { my ($class, @packages) = @_; bless { packages => [@packages] }, $class }
    sub dbh  { $_[0] }
    sub selectcol_arrayref { [ @{ $_[0]{packages} } ] }
}

sub write_docs_json_for {
    my ($latest, $cb) = @_;

    no warnings 'redefine';
    local *PJP::M::PodFile::get_latest = sub { $latest->{$_[1]} };

    in_tempdir sub {
        main::create_docs_json(Test::Pjp->new(keys %$latest));
        # strict にデコードできること = 生成側が UTF-8 のバイト列を書いていること
        $cb->(JSON::XS->new->utf8->decode(slurp_bytes('static/docs.json')));
    };
}

subtest 'docs.json は非 ASCII の package/path を壊さずに書き出す' => sub {
    write_docs_json_for { 'Acme::日本語' => 'modules/Acme-日本語-1.00/日本語.pod' }, sub {
        is $_[0]{'Acme::日本語'}, 'modules/Acme-日本語-1.00/日本語.pod',
            'package も path も読み戻せる';
    };
};

subtest 'docs.json は latin-1 の範囲の文字も壊さない' => sub {
    # U+0100 以上を含む文字列は内部表現がたまたま UTF-8 になるため、encode の
    # 指定を落としても正しいバイト列に見える。latin-1 の範囲に収まる文字だけの
    # 場合は内部表現が 1 バイトのままで、指定が無ければ不正な UTF-8 になる
    write_docs_json_for { 'Café::Módulo' => 'modules/Café-Módulo-1.00/Módulo.pod' }, sub {
        is $_[0]{'Café::Módulo'}, 'modules/Café-Módulo-1.00/Módulo.pod',
            'é が含まれていても読み戻せる';
    };
};

subtest 'RSS は非 ASCII の author/name/path を壊さずに書き出す' => sub {
    my @updates = ({
        date    => '2026-06-01 12:00:00',
        # latin-1 の範囲の文字を混ぜる (日本語だけだと、encoding の指定を
        # 落としても内部表現がたまたま UTF-8 になって通ってしまう)
        author  => 'José 翻訳者',
        path    => 'docs/modules/Acme-日本語-1.00/日本語.pod',
        name    => 'Acme::日本語',
        in      => 'Acme::日本語',
        version => '1.00',
    });

    in_tempdir sub {
        main::create_rss(\@updates);

        # XML::RSS は非 ASCII を数値文字参照にするので、ファイルは ASCII の
        # 範囲に収まる。宣言した encoding と実バイト列が食い違っていないことは、
        # パーサに通して値が復元できるかで見る
        my $bytes = slurp_bytes('static/rss/recent.rss');
        is scalar(() = $bytes =~ /[\x80-\xff]/g), 0, '生の非 ASCII バイトを書かない';

        my $rss = XML::RSS->new;
        $rss->parse($bytes);
        my $item = $rss->{items}[0];
        is $item->{title}, 'Acme::日本語', 'title に翻訳名が残る';
        like $item->{description}, qr/José 翻訳者/, 'description に翻訳者が残る';
        like $item->{link}, qr{Acme-日本語-1\.00}, 'link に path が残る';
    };
};

done_testing;
