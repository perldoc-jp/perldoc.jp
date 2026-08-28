use v5.38;
use utf8;
use Test2::V0;

use PJP::M::Pod;
use PJP::M::PodFile ();
use PJP::HTMLDiff ();
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

        # 一覧に nobr は入れない。<nobr> は Pod::Simple::HTML が S<> に対して
        # 出すもので、Pod::Simple::XHTML は版に関係なく出さないため、
        # ok $open > 0 に必ず落ちる
        my $testee = $html;
        for my $tag (qw/div pre p h1 h2 code b a ul li i/) {
            my ($open, $close) = (0, 0);
            $testee =~ s/<$tag[^>]*>/$open++/gei;
            $testee =~ s!</$tag[^>]*>!$close++!gei;
            ok $open > 0, "$tag があり、";
            ok $open == $close, '開始タグと終了タグの数が一致している';
        }
    };

    # Pod::Simple::XHTML 3.29 以降、start_for が開いた <div class="original"> は
    # emit されずに scratch へ滞留する。原文ブロックの先頭が scratch を代入で
    # 上書きする要素 (verbatim / =over / =head) だと開きタグだけが消え、
    # </div> が余って DOM が壊れる。lib/PJP/M/Pod.pm の start_for override が
    # 3.28 と同じく開いた時点で流し切ることで防いでいる
    my %original_shape = (
        verbatim => "    my \$x = 1;\n",
        over     => "=over 4\n\n=item foo\n\nbar\n\n=back\n",
        head     => "=head2 Some Heading\n\nbody\n",
    );

    subtest '原文ブロックの先頭がどの要素でも div が閉じきる' => sub {
        for my $name (sort keys %original_shape) {
            subtest $name => sub {
                my $pod = "=encoding utf-8\n\n=head1 NAME\n\nSample - $name\n\n"
                        . "=begin original\n\n$original_shape{$name}\n=end original\n\n訳文。\n";
                my $html = PJP::M::Pod->pod2html(\$pod);
                my $open  = () = $html =~ /<div/g;
                my $close = () = $html =~ m{</div>}g;
                is $open, $close, '<div> と </div> の数が一致する';
                like $html, qr{<div class="original">}, '原文ブロックの開きタグがある';
            };
        }
    };

    subtest '原文ブロックの先頭が見出しでも見出しのマーカーが漏れない' => sub {
        # =head が先頭だと _end_head が滞留中の div ごと見出しテキストとして
        # 取り込み、end_Document の TRANHEADSTART...TRANHEADEND の置換が改行を
        # またげずに失敗してマーカーが本文に出る。div の数だけ見ると釣り合って
        # しまうので、独立して確かめる。
        # 見出しは必ず中身のあるものにすること — 空の =head1 は (.+?) が
        # 空文字にマッチしない別の既知バグ (Net/Netrc.pod) を踏む
        my $pod = "=encoding utf-8\n\n=head1 NAME\n\nSample - head\n\n"
                . "=begin original\n\n$original_shape{head}\n=end original\n\n"
                . "=head2 とある見出し\n\n訳文。\n";
        my $html = PJP::M::Pod->pod2html(\$pod);
        unlike $html, qr/TRANHEAD(?:START|END)/, 'マーカーが出力に残らない';
        unlike $html, qr{<li><a href="[^"]*"><div}, '目次のリンク文字列に div が混ざらない';
    };

    subtest '=begin html は literal region のまま扱う' => sub {
        # literal xhtml region では start_for が early return するので、
        # 3.29 以降の挙動 (div を出さない) を変えない
        my $pod = "=encoding utf-8\n\n=head1 NAME\n\nSample - html\n\n"
                . "=begin html\n\n<b>raw</b>\n\n=end html\n\n訳文。\n";
        my $html = PJP::M::Pod->pod2html(\$pod);
        my $open  = () = $html =~ /<div/g;
        my $close = () = $html =~ m{</div>}g;
        is $open, $close, '<div> と </div> の数が一致する';
        unlike $html, qr{<div class="html">}, 'literal region に div を足さない';
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

subtest 'diff のタイムアウトは呼び出し元の指定に依らず常に張られる' => sub {
    # timeout を引数で受けていた頃は、既定が「張らない」で、唯一の呼び出し元が
    # 明示していたから効いていた。呼び出しが増えると素通しの経路ができる
    my $pod = { path => 'modules/Foo-1.00/Foo.pod', package => 'Foo' };
    no warnings qw/redefine once/;
    local *PJP::M::PodFile::retrieve = sub { $pod };
    local *PJP::M::PodFile::slurp    = sub { "=encoding utf-8\n\n=head1 NAME\n\nFoo\n" };

    subtest 'タイムアウトすると error => timeout を返す' => sub {
        local $PJP::M::Pod::DIFF_TIMEOUT = 1;
        local *PJP::HTMLDiff::diff_strings_vertical = sub { sleep 3; 'never' };
        my $warned = '';
        local $SIG{__WARN__} = sub { $warned .= $_[0] };

        my $out = PJP::M::Pod->diff(
            'modules/Foo-1.00/Foo.pod', 'modules/Foo-1.01/Foo.pod');
        is $out->{error}, 'timeout', 'timeout を返す';
        like $warned, qr/diff timeout/, '警告を残す';
        is alarm(0), 0, 'タイマーが残らない';
    };

    subtest 'timeout 以外の die は伝播し、タイマーも残さない' => sub {
        local $PJP::M::Pod::DIFF_TIMEOUT = 30;
        local *PJP::HTMLDiff::diff_strings_vertical = sub { die "boom\n" };

        like dies {
            PJP::M::Pod->diff('modules/Foo-1.00/Foo.pod', 'modules/Foo-1.01/Foo.pod')
        }, qr/boom/, 'die がそのまま伝播する';
        is alarm(0), 0, 'タイマーが残らない';
    };
};

done_testing;

