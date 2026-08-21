use v5.38;
use utf8;
use Test2::V0;

use Cwd ();
use Encode ();
use File::Temp qw/tempdir/;
use Data::Dumper ();
use JSON::XS ();
use POSIX ();
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

subtest 'write_data_pl の書き出しは呼び出し元の Dumper 設定に依らない' => sub {
    # 設定をファイルスコープの local に置いていた頃は、require が終わった
    # 時点で巻き戻るため、生成の各段を直接呼ぶこのテストからは効いていなかった。
    # 呼び出し前に 4 つを意図と逆の値へ倒しておく — 既定値のまま呼ぶと、
    # 関数内の local を 1 つ削っても環境次第で通ってしまう
    local $Data::Dumper::Terse    = 0;
    local $Data::Dumper::Sortkeys = 0;
    local $Data::Dumper::Useqq    = 0;
    local $Data::Dumper::Indent   = 0;

    in_tempdir(sub {
        # Indent の 1 と 2 は平坦なハッシュだと同じ見た目になるので、
        # 入れ子を持たせて違いが出るようにする
        my $data = { b => 'あ', a => { inner => [1, 2] } };

        write_data_pl('out.pl', $data);
        my $default = Encode::decode_utf8(slurp_bytes('out.pl'));
        like $default, qr{\A\+\{\n},    'Terse=1 で $VAR1 が付かない';
        like $default, qr{"b" => "},    'Useqq=1 でキーも値もダブルクォートになる';
        like $default, qr{\\x\{3042\}}, '非 ASCII は \x{} にエスケープされる';
        ok index($default, '"a" =>') < index($default, '"b" =>'),
            'Sortkeys=1 でキーが整列する';
        like $default, qr{"inner" => \[\n\s{20,}1,}, 'Indent=2 で入れ子が深く揃う';

        write_data_pl('out1.pl', $data, indent => 1);
        my $indent1 = Encode::decode_utf8(slurp_bytes('out1.pl'));
        like $indent1, qr{"inner" => \[\n\s{6}1,}, 'indent => 1 では固定幅で下がる';
        isnt $indent1, $default, 'indent の指定で書き出しが変わる';
    });
};

subtest 'RSS の日時が RFC 822 の英語表記に固定される' => sub {
    my @updates = (
        { date => '2026-06-01 12:00:00', author => 'a', path => 'docs/p1.pod',
          name => 'P1', in => '', version => '' },
        { date => '2026-05-31 09:08:07', author => 'b', path => 'docs/p2.pod',
          name => 'P2', in => '', version => '' },
    );

    # 3 つすべて (channel の pubDate / lastBuildDate と item ごとの pubDate) を
    # 見る。channel だけだと item 側の書式を落としても通る
    my $check = sub {
        my ($label) = @_;
        my $rss = XML::RSS->new;
        $rss->parse(slurp_bytes('static/rss/recent.rss'));
        is $rss->{channel}{pubDate},       'Mon, 01 Jun 2026 12:00:00 +0900', "$label: channel pubDate";
        is $rss->{channel}{lastBuildDate}, 'Mon, 01 Jun 2026 12:00:00 +0900', "$label: channel lastBuildDate";
        is $rss->{items}[0]{pubDate},      'Mon, 01 Jun 2026 12:00:00 +0900', "$label: item[0] pubDate";
        is $rss->{items}[1]{pubDate},      'Sun, 31 May 2026 09:08:07 +0900', "$label: item[1] pubDate";
    };

    in_tempdir sub {
        main::create_rss(\@updates);
        $check->('既定のロケール');
    };

    subtest 'ロケール依存の strftime を通らない' => sub {
        # ja_JP.UTF-8 を掛ける下の subtest はロケールが無い環境で skip される。
        # C ロケールでは Time::Piece->strftime でも英語の曜日・月名が出るため、
        # 完全一致テストだけでは実装を戻しても気づけない。RSS の生成中だけ
        # ロケール依存 API を禁止して、経路そのものを固定する。
        #
        # 囲む範囲は create_rss の呼び出しに限る — cutoff 計算や
        # Repository の未来日検査も Time::Piece->strftime を使うが、そちらは
        # '%Y-%m-%d %H:%M:%S' でロケールに依存しないので対象ではない
        in_tempdir sub {
            no warnings qw/redefine once/;
            local *Time::Piece::strftime = sub {
                die 'locale-sensitive strftime must not be used while building the feed';
            };
            ok lives { main::create_rss(\@updates) }, 'Time::Piece::strftime を呼ばずに書き出せる';
            $check->('strftime 禁止下');
        };
    };

    subtest 'ja_JP.UTF-8 でも英語表記になる' => sub {
        # setlocale はプロセス全体に効き local では戻らないので、
        # 元の LC_TIME を保存して成否によらず復元する。
        # そのロケールが無い環境では skip されるため、部分的な検出器
        my $orig = POSIX::setlocale(POSIX::LC_TIME());
        skip_all 'ja_JP.UTF-8 is not available'
            unless defined POSIX::setlocale(POSIX::LC_TIME(), 'ja_JP.UTF-8');
        my $guard = Guard->new(sub { POSIX::setlocale(POSIX::LC_TIME(), $orig) });

        in_tempdir sub {
            main::create_rss(\@updates);
            $check->('ja_JP.UTF-8');
        };
    };
};

done_testing;
