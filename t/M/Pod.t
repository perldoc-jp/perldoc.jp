use v5.38;
use utf8;
use Test2::V0;

use PJP::M::Pod;
use PJP;

my $c = PJP->bootstrap;

my $pod = <<'...';
foo
bar
__END__

=head1 NAME

B<OK> - あれです

=head1 SYNOPSIS

    This is a sample pod

=head1 注意

=head1 GETTING HELP

(ヘルプを見る)

perldoc プログラムは、Perl と共に配布されている全ての文書を読むための プログラムです。 http://www.perl.org/ では、さらなる文書、チュートリアル、コミュニティ サポポートがオンラインで得られます。

=head1 理解されるフォーマット

L<"SYNOPSIS">

L<"注意">

...

subtest 'pod2html' => sub {

    subtest 'PODを期待通りparseして、HTML化できているか' => sub {
        my $html = PJP::M::Pod->pod2html(\$pod);
        # 目次
        like $html, qr{<li><a href="\#pod27880-24847">注意</a></li>};
        like $html, qr{<li><a href="\#GETTING32HELP">ヘルプを見る</a></li>};

        # 見出し
        like $html, qr{<h1 id="pod27880-24847">注意<a href="\#27880-24847" class="toc_link">&\#182;</a></h1>};
        like $html, qr{<h1 id="GETTING32HELP">ヘルプを見る<a href="\#GETTING32HELP" class="toc_link">&\#182;</a></h1>};

        todo 'pod2html', sub {
            fail 'GETTING32HELP のhrefが目次と見出しで重複しているので調整した方が良さそう';
        };
    };

    subtest 'HTMLタグが閉じられてるか' => sub {
        my $html = PJP::M::Pod->pod2html("@{[$c->assets_dir]}translation/docs/perl/5.12.1/perl.pod");

        todo 'pod2html', sub {
            fail 'HTMLタグが閉じられているかのテストが失敗している';
        };

        # my $testee = $html;
        # for my $tag (qw/div pre p h1 h2 code b a ul li nobr i/) {
        #     my ($open, $close) = (0, 0);
        #     $testee =~ s/<$tag[^>]*>/$open++/gei;
        #     $testee =~ s!</$tag[^>]*>!$close++!gei;
        #     ok $open > 0, "$tag があり、";
        #     ok $open == $close, '開始タグと終了タグの数が一致している';
        # }
    };
};

subtest '同じ訳語の見出しが複数あってもアンカーが揺れない' => sub {
    # 訳語から英語の見出しを引き戻す表は、同じ訳語を持つ見出しが複数あると
    # どちらが勝つかがハッシュの列挙順で決まっていた (実データでは
    # CPAN::Meta::Spec の "Version Range" と "Version Ranges" が該当し、
    # 生成される HTML が実行ごとに変わっていた)
    # 見出しの直後に (訳語) を置くのが、この pod 群での訳の付け方
    my $dup = <<'...';
=encoding utf-8

=head1 NAME

Dup - 重複した訳語

=head2 Version Range

(バージョンの範囲)

=head2 Version Ranges

(バージョンの範囲)

=head1 SEE ALSO

L</バージョンの範囲>
...

    my $html = PJP::M::Pod->pod2html(\$dup);
    my ($anchor) = $html =~ m{href="#(Version Ranges?)"};
    is $anchor, 'Version Range', '英語見出しの辞書順で先のものに固定される';
};

subtest 'parse_name_section' => sub {
    my ($pkg, $desc) = PJP::M::Pod->parse_name_section(\$pod);
    is $pkg, 'OK';
    is $desc, 'あれです';

    subtest 'wt.pod' => sub {
        my $path = "@{[$c->assets_dir]}translation/docs/modules/HTTP-WebTest-2.04/bin/wt.pod";
        my ($pkg, $desc) = PJP::M::Pod->parse_name_section($path);
        is $pkg, 'wt';
        is $desc, '１つもしくは複数のウェブページのテスト';
    };
};

done_testing;

