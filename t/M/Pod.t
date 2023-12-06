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

