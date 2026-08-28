use strict;
use warnings;
use utf8;

package PJP::M::Pod;
use Pod::Simple::XHTML;
use Log::Minimal;
use Text::Xslate::Util qw/mark_raw html_escape/;
use Encode ();
use HTML::Entities ();
use Amon2::Declare;
use PJP::HTMLDiff ();

sub parse_name_section {
    my ($class, $stuff) = @_;
    my $src = do {
        if (ref $stuff) {
            $$stuff;
        } else {
            open my $fh, '<:raw', $stuff or die "Cannot open file $stuff: $!";
            my $src = do { local $/; <$fh> };
            if ($src =~ /^=encoding\s+(euc-jp|utf-?8)/sm) {
                $src = Encode::decode($1, $src);
            }
            $src;
        }
    };
    $src =~ s/=begin\s+original.+?=end\s+original\n//gsm;
    $src =~ s/X<[^>]+>//g;
    $src =~ s/=encoding\s+\S+\n//gsm;
    $src =~ s/\r\n/\n/g;

    my ($package, $description) = ($src =~ m/
        ^=head1\s+(?:NAME|題名|名前|名前\ \(NAME\))[ \t]*\n(?:名前\n)?\s*\n+\s*
        \s*(\S+)(?:\s*-+\s*([^\n]+))?
    /msx);

    $package     =~ s/[A-Z]<(.+?)>/$1/g if $package;        # remove tags
    $description =~ s/[A-Z]<(.+?)>/$1/g if $description;    # remove tags
    return ($package, $description || '');
}

sub pod2html {
        my ($class, $stuff) = @_;
        $stuff or die "missing mandatory argument: $stuff";

    my $parser = PJP::Pod::Parser->new();
    $parser->html_encode_chars(q{&<>"'});
    $parser->accept_targets_as_text('original');
    $parser->html_header('');
    $parser->html_footer('');
    $parser->index(1); # display table of contents
        $parser->perldoc_url_prefix('/pod/');
    $parser->output_string(\my $out);
    # $parser->html_h_level(3);
        if (ref $stuff eq 'SCALAR') {
                $parser->parse_string_document($$stuff);
        } else {
                $parser->parse_file($stuff);
        }
        return mark_raw($out);
}

sub get_file_list {
        my ($class, $name) = @_;

    my @path = reverse sort { eval { version->parse($a->[1]) } <=> eval { version->parse($b->[1]) } } map {
        +[ $_, map { local $_=$_; s!.*/perl/!!; s!/$name.pod!!; $_ } $_ ]
    } glob("@{[ c()->assets_dir() ]}/translation/docs/perl/*/$name.pod");
        return @path;
}

sub get_latest_file_path {
        my ($class, $name) = @_;
        my ($latest) = $class->get_file_list($name);
        return $latest;
}

{
    package PJP::Pod::Parser;
    use Pod::Simple::XHTML;
    use parent qw/Pod::Simple::XHTML/;
    use URI::Escape qw/uri_escape_utf8/;

    sub new {
        my $self = shift->SUPER::new(@_);
        $self->{translated_toc} = +{
            'NAME'                  => '名前',
            'SYNOPSIS'              => '概要',
            'DESCRIPTION'           => '説明',
            'AUTHOR'                => '作者',
            'AUTHORS'               => '作者',
            'OPTION'                => 'オプション',
            'OPTIONS'               => 'オプション',
            'METHOD'                => 'メソッド',
            'METHODS'               => 'メソッド',
            'FUNCTION'              => '関数',
            'FUNCTIONS'             => '関数',
            'EXAMPLE'               => '例',
            'EXAMPLES'              => '例',
            'COPYRIGHT AND LICENSE' => 'コピーライト & ライセンス',
            'COPYRIGHT & LICENSE'   => 'コピーライト & ライセンス',
            'COPYRIGHT'             => 'コピーライト',
            'LICENSE'               => 'ライセンス',
            'BUGS'                  => 'バグ',
            'CAUTION'               => '警告',
            'ACKNOWLEDGEMENTS'      => '謝辞',
            'SUPPORT'               => 'サポート',
        };
        return $self;
    }

    # Pod::Simple::XHTML 3.29 (2015-02) で start_for が emit しなくなり、開いた
    # <div class="original"> が scratch に残るようになった。start_Verbatim や
    # start_over_* / _end_head は scratch を代入で上書きするため、その div が
    # 消えて </div> だけが残る (=head が先頭に来たときは div が見出しの中へ
    # 紛れ込み、TRANHEADSTART マーカーの置換まで壊す)。CPAN 最新の 3.48 でも
    # 直っていないので、3.28 (旧 VPS の perl 5.18.2) と同じく、開いた時点で
    # 流し切る。
    sub start_for {
        my ($self, $flags) = @_;
        $self->SUPER::start_for($flags);
        return if $self->__in_literal_xhtml_region;
        # 3.28 は ">" までしか積まなかった。ここで末尾の改行を落としておくと、
        # end_Document の join("\n\n", ...) が同じ位置に改行を戻すので、
        # 1 回で emit していた頃と出力がバイト単位で一致する
        $self->{scratch} =~ s/\s+\z//;
        $self->emit;
    }

    # for google source code prettifier
    sub start_Verbatim {
        $_[0]{'scratch'} = '<pre class="prettyprint lang-perl"><code>';
    }
    sub end_Verbatim {
        $_[0]{'scratch'} .= '</code></pre>';
        $_[0]->emit;
    }

    sub _end_head {
        $_[0]->{last_head_body} = $_[0]->{scratch};
        $_[0]->{end_head}  = 1;

        my $h = delete $_[0]{in_head};

        my $add = $_[0]->html_h_level;
           $add = 1 unless defined $add;
        $h += $add - 1;

        my $id = $_[0]->idify($_[0]{scratch});
        # 直後の handle_text が拾う訳語を、この見出しの実 id に結びつける
        $_[0]->{last_head_id} = $id;
        my $text = $_[0]{scratch};
        # あとで翻訳したリソースと置換できるように、印をつけておく
        $_[0]{'scratch'} = sprintf(qq{<h$h id="$id">TRANHEADSTART%sTRANHEADEND<a href="#$id" class="toc_link">&#182;</a></h$h>}, $text);
        $_[0]->emit;
        push @{ $_[0]{'to_index'} }, [$h, $id, $text];
    }
    sub end_head1       { shift->_end_head(@_); }
    sub end_head2       { shift->_end_head(@_); }
    sub end_head3       { shift->_end_head(@_); }
    sub end_head4       { shift->_end_head(@_); }

    sub handle_text {
        my ($self, $text) = @_;
        if (defined $_[0]->{end_head} && $_[0]->{end_head}-- > 0 && $text =~ /^\((.+)\)$/) {
            # 最初の行の括弧でかこまれたものがあったら、それは翻訳された見出しとみなす
            # 仕様については Pod::L10N を見よ
            $_[0]->{translated_toc}->{$_[0]->{last_head_body}} = $1;
            # 訳語で書かれた L</...> が作る href を、その訳語が付いた見出しの
            # 実 id へ寄せる。鍵は自分で組まず resolve_pod_page_link から取る
            # (リンク解決と鍵生成に同じ規則を使えば、同一実行内でずれない)。
            # 同じ訳語を持つ見出しが複数ある pod があるので (CPAN::Meta::Spec の
            # "Version Range" と "Version Ranges" はどちらも「バージョンの範囲」)、
            # //= で先に現れた見出しに固定する
            $_[0]->{anchor_of_translation}->{ $_[0]->resolve_pod_page_link(undef, $1) }
                //= '#' . $_[0]->{last_head_id};
        } else {
            $self->SUPER::handle_text($text);
        }
    }

    # idify がマルチバイトクリーンじゃないから適当に対応してある。
    sub idify {
        my ($self, $t, $not_unique) = @_;
        for ($t) {
            s/<[^>]+>//g;            # Strip HTML.
            s/&[^;]+;//g;            # Strip entities.
            s/^\s+//; s/\s+$//;      # Strip white space.
            s/^([^a-zA-Z]+)$/pod$1/; # Prepend "pod" if no valid chars.
#           s/^[^a-zA-Z]+//;         # First char must be a letter.
            s/([^-a-zA-Z0-9_:.]+)/join '-', unpack("U*", $1)/eg; # All other chars must be valid.
#            s/([^-a-zA-Z0-9_:.]+)/unpack("U*", $1)/eg; # All other chars must be valid.
        }
        return $t if $not_unique;
        my $i = '';
        $i++ while $self->{ids}{"$t$i"}++;
        return "$t$i";
    }

    sub end_Document {
        my ($self) = @_;
        my $to_index = $self->{'to_index'};

        if ( $self->index && @{$to_index} ) {
            my @out;
            my $level  = 0;
            my $indent = -1;
            my $space  = '';
            my $id     = ' class="pod_toc"';

            for my $h ( @{$to_index}, [0] ) {
                my $target_level = $h->[0];

                # Get to target_level by opening or closing ULs
                if ( $level == $target_level ) {
                    $out[-1] .= '</li>';
                }
                elsif ( $level > $target_level ) {
                    $out[-1] .= '</li>' if $out[-1] =~ /^\s+<li>/;
                    while ( $level > $target_level ) {
                        --$level;
                        push @out, ( '  ' x --$indent ) . '</li>'
                          if @out && $out[-1] =~ m{^\s+<\/ul};
                        push @out, ( '  ' x --$indent ) . "</ul>";
                    }
                    push @out, ( '  ' x --$indent ) . '</li>' if $level;
                }
                else {
                    while ( $level < $target_level ) {
                        ++$level;
                        push @out, ( '  ' x ++$indent ) . '<li>'
                          if @out && $out[-1] =~ /^\s*<ul/;
                        push @out, ( '  ' x ++$indent ) . "<ul$id>";
                        $id = '';
                    }
                    ++$indent;
                }

                next unless $level;

                $space = '  ' x $indent;
                # 見出しが翻訳されていれば、翻訳されたものをつかう
                my $text = $h->[2];
                if ($self->{translated_toc}->{$text}) {
                    $text = $self->{translated_toc}->{$text};
                }
                push @out, sprintf '%s<li><a href="#%s">%s</a>',
                  $space, $h->[1], $text;
            }

            print { $self->{'output_fh'} } join "\n", @out;
        }

        my $output = join( "\n\n", @{ $self->{'output'} } );

        # 訳語で書かれた L</..> を、その訳語が付いた見出しの実 id へ寄せる
        my $anchor = $self->{anchor_of_translation} || {};
        # 実在する見出しへのリンクは訳語表より優先する。鍵は
        # resolve_pod_page_link が作る fragment 表現なので、実在 id 側も同じ
        # encode_url を通さないと一致しない (idify('Foo:Bar') は 'Foo:Bar'
        # だが L</Foo:Bar> は '#Foo%3ABar' になる)
        my %real = map { ('#' . $self->encode_url($_->[1]), 1) } @{$to_index};
        delete $anchor->{$_} for grep { $real{$_} } keys %$anchor;
        # 表に無い href は無変換で通す
        $output =~ s{href="(#[^"]*)"}{ 'href="' . ($anchor->{$1} // $1) . '"' }eg;

        $output =~ s[TRANHEADSTART(.+?)TRANHEADEND][
            if (my $translated = $self->{translated_toc}->{$1}) {
                $translated;
            } else {
                $1;
            }
        ]ge;
        print { $self->{'output_fh'} }
            qq{\n\n<div class="pod_content_body">$output\n\n</div>};
        @{ $self->{'output'} } = ();
    }
}

# diff にかける秒数。0 以下にすると alarm を張らない。
#
# 呼び出し元から渡す形にしていた頃は、既定が「タイムアウトなし」で、
# 唯一の呼び出し元 (Dispatcher) が明示していたから効いていた。呼び出しが
# 増えたときに素通しの経路ができるので、既定をここに持たせる
our $DIFF_TIMEOUT = 6;

sub diff {
    my ($self, $origin, $target) = @_;

    # target はクエリパラメータ由来で、未指定のままアクセスされうる
    if (!defined $target || $target eq '') {
        return {error => 'no_pod'};
    }

    if ($origin =~m{perl[\w-]*delta\.pod} or $target =~m{perl[\w-]*delta\.pod}) {
        return {error => 'perldelta'};
    }

    my ($origin_pod_name) = $origin =~ m{([^/]+\.pod)};
    my ($target_pod_name) = $target =~ m{([^/]+\.pod)};

    if (!defined $origin_pod_name or !defined $target_pod_name
        or $origin_pod_name ne $target_pod_name) {
        return {error => 'different_file'};
    }

    # DB に無い pod は slurp より先にここで弾く (undef のまま進めると
    # 下の {%$pod, ...} が undef デリファレンスで die し 500 になる)
    my $pod = PJP::M::PodFile->retrieve($origin)
        or return {error => 'no_pod'};

    my $origin_content = PJP::M::PodFile->slurp($origin) // return {%$pod, error => 'no_pod'};
    my $target_content = PJP::M::PodFile->slurp($target) // return {%$pod, error => 'no_pod'};

    my ($origin_charset) = ($origin_content =~ /=encoding\s+(euc-jp|utf-?8)/);
        $origin_charset //= 'utf-8';
    my ($target_charset) = ($target_content =~ /=encoding\s+(euc-jp|utf-?8)/);
        $target_charset //= 'utf-8';

    $origin_content = Encode::decode($origin_charset, $origin_content);
    $target_content = Encode::decode($target_charset, $target_content);

    my $diff;
    local $@;
    # ハンドラは alarm の解除より外側で生かす。eval の中で local すると、
    # eval を抜けた時点でハンドラだけが先に復元され、そこから alarm 0 に
    # 到達するまでの隙間に残タイマーが着弾するとデフォルト動作
    # (プロセス終了) でワーカーが即死する
    local $SIG{ALRM} = sub { die "diff timeout" };
    eval {
        if ($DIFF_TIMEOUT > 0) {
            alarm $DIFF_TIMEOUT;
        }
        $diff = PJP::HTMLDiff::diff_strings_vertical($target_content, $origin_content);
    };
    # timeout 以外の die でも必ず解除する
    alarm 0;
    if ($@ =~m{diff timeout}) {
        warn "diff timeout: $origin $target";
        return {%$pod, error => 'timeout'};
    } elsif ($@) {
        die $@;
    }

    return { %$pod, diff => $diff };
}

1;

