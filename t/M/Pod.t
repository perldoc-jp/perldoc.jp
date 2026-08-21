use v5.38;
use utf8;
use Test2::V0;

use PJP::M::Pod;
use PJP;
use URI::Escape ();

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
        like $html, qr{<h1 id="pod27880-24847">注意<a href="\#pod27880-24847" class="toc_link">&\#182;</a></h1>};
        like $html, qr{<h1 id="GETTING32HELP">ヘルプを見る<a href="\#GETTING32HELP" class="toc_link">&\#182;</a></h1>};
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
    # 同じ訳語を持つ見出しが複数ある pod がある (実データでは
    # CPAN::Meta::Spec の "Version Range" と "Version Ranges" がどちらも
    # 「バージョンの範囲」)。訳語 -> 実 id の表は handle_text で //= により
    # 先に現れた見出しに固定されるので、ハッシュの列挙順に依存しない。
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
    my ($anchor) = $html =~ m{href="#(Version32Ranges?)"};
    is $anchor, 'Version32Range', '先に現れた見出しの実 id に寄る';
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

# 訳語が実在の見出し名と衝突する pod。実在見出しへのリンクは訳語表より優先する。
# 鍵は resolve_pod_page_link が作る fragment 表現なので、実在 id 側も encode_url を
# 通さないと一致しない。(a) は encode_url が恒等なケース、(b) は逃がすケースで、
# (b) は生の '#' . $id で表を作ると取りこぼす
my $collide = <<'...';
=encoding utf-8

=head1 NAME

Collide - 訳語と実在見出しの衝突

=head2 Alpha

(注意)

=head2 注意

=head2 Beta

(Foo:Bar)

=head2 Foo:Bar

=head1 SEE ALSO

L</注意>

L</Foo:Bar>
...

subtest '実在の見出しへのリンクは訳語表より優先する' => sub {
    my $html = PJP::M::Pod->pod2html(\$collide);

    subtest 'encode_url が恒等なケース' => sub {
        like $html, qr{<h2 id="pod27880-24847">注意<a href="\#pod27880-24847"},
            '実在する「注意」の見出しがある';
        like $html, qr{<p><a href="\#pod27880-24847">&quot;注意&quot;</a></p>},
            'L</注意> は訳語が付いた Alpha ではなく実在見出しを指す';
    };

    subtest 'encode_url が逃がすケース' => sub {
        like $html, qr{<h2 id="Foo:Bar">Foo:Bar<a href="\#Foo:Bar"},
            '実在する「Foo:Bar」の見出しがある';
        like $html, qr{<p><a href="\#Foo%3ABar">&quot;Foo:Bar&quot;</a></p>},
            'L</Foo:Bar> は訳語が付いた Beta ではなく実在見出しを指す';
    };

    subtest '見出しの ¶ リンクが自分の id を指す' => sub {
        my @mismatch;
        while ($html =~ m{<h\d id="([^"]+)">.*?<a href="\#([^"]+)" class="toc_link"}g) {
            push @mismatch, [$1, $2] if $1 ne $2;
        }
        is \@mismatch, [], 'id と ¶ の href が全ての見出しで一致する';
    };
};

subtest 'href の指す先が全て実在の id になっている' => sub {
    # href は percent-encode 済み、id は生なので、同じ空間に揃えてから比べる
    # (素の比較だと #Foo%3ABar を宛先無しと誤判定する)。
    # 対象は手書き fixture に限る — 実 corpus は =item 宛ての宛先無しリンクを
    # 多数持っており、それはこの修正の範囲外
    my $dup_local = <<'...';
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

    for my $case ([collide => \$collide], [dup => \$dup_local]) {
        my ($name, $ref) = @$case;
        my $html = PJP::M::Pod->pod2html($ref);
        my %id = map { $_ => 1 } $html =~ m{<h\d id="([^"]+)"}g;
        my @dangling =
            grep { !$id{$_} }
            map  { URI::Escape::uri_unescape($_) }
            $html =~ m{href="\#([^"]*)"}g;
        is \@dangling, [], "$name: 宛先の無い fragment が無い";
    }
};

subtest '組み込み辞書由来の訳語は解決の対象外' => sub {
    # translated_toc の組み込み辞書 (NAME -> 名前) は pod 中の (訳語) マーカーでは
    # ないので anchor_of_translation には入らない。L</名前> は未解決のままになる
    my $builtin = <<'...';
=encoding utf-8

=head1 NAME

Builtin - 組み込み辞書

=head1 SEE ALSO

L</名前>
...
    my $html = PJP::M::Pod->pod2html(\$builtin);
    like $html, qr{<p><a href="\#pod21517-21069">&quot;名前&quot;</a></p>},
        'NAME の実 id (#NAME) には寄らない';
};

subtest '訳語表が文書をまたいで漏れない' => sub {
    # parser は pod2html ごとに new されるので、前の文書の訳語で
    # 次の文書のリンクが書き換わることはない
    PJP::M::Pod->pod2html(\$collide);
    my $second = <<'...';
=encoding utf-8

=head1 NAME

Second - 二本目

=head1 SEE ALSO

L</注意>
...
    my $html = PJP::M::Pod->pod2html(\$second);
    like $html, qr{<p><a href="\#pod27880-24847">&quot;注意&quot;</a></p>},
        '一本目の「注意」の見出し id に引きずられない';
};

done_testing;

