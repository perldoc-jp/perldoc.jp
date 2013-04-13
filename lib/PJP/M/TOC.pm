use strict;
use warnings;
use utf8;

package PJP::M::TOC;
use Text::Xslate::Util qw/html_escape mark_raw/;
use File::stat;
use Log::Minimal;
use Pod::Functions;

sub render {
    my ($class, $c) = @_;
    $c // die;

    return mark_raw($c->cache->file_cache
                    (
                     "toc:4", 'toc.txt', sub {
                         infof("regen toc");
                         my $ret = $class->_render();
                         return $ret;
                     }
                    ));
}

sub _render {
    my ($class) = @_;

    open my $fh, '<:utf8', 'toc.txt' or die "Cannot open toc.txt: $!";
    my $out;
    my $started = 0;
    while (<$fh>) {
        chomp;
        if (!/\S/) {
            next;
        } elsif (/^\s*\#/) {
            next;                       # comment line
        } elsif (/^\S/) {               # header line
            $out .= "</ul>" if $started++;
            $out .= sprintf("<h3>%s</h3><ul>\n", html_escape($_));
        } else {                        # main line
            s/^\s+//;
            my ($pkg, $desc) = split /\s*-\s*/, $_;
            $out .= sprintf('<li><a href="/pod/%s">%s</a>', (html_escape($pkg))x2);
            if ($desc) {
                $out .= sprintf(' - %s', html_escape($desc));
            }
            $out .= "</li>\n";
        }
    }
    $out .= "</ul>" if $started;
    $out;
}

my %func_kind2jp = (
                    'String'       => 'スカラや文字列のための関数',
                    'Regexp'       => '正規表現とパターンマッチング',
                    'Math'         => '数値関数',
                    'ARRAY'        => '実配列のための関数',
                    'LIST'         => 'リストデータのための関数',
                    'HASH'         => '実ハッシュのための関数',
                    'I/O'          => '入出力関数',
                    'File'         => 'ファイルハンドル、ファイル、ディレクトリのための関数',
                    'Flow'         => 'プログラムの流れを制御することに関連するキーワード',
                    'Binary'       => '固定長データやレコードのための関数',
                    'Namespace'    => 'スコープに関するキーワード',
                    'Misc'         => 'さまざまな関数',
                    'Process'      => 'プロセスとプロセスグループのための関数',
                    'Modules'      => 'Perl モジュールに関するキーワード',
                    'Objects'      => 'クラスとオブジェクト指向に関するキーワード',
                    'Socket'       => '低レベルソケット関数',
                    'SysV'         => 'System V プロセス間通信関数',
                    'User'         => 'ユーザーとグループの情報取得',
                    'Time'         => '時間関係の関数',
                    'Network'      => 'ネットワークの情報の取得',

                   );

sub render_function {
    my ($class, $c) = @_;
    my $out = '';
    foreach my $type (@Pod::Functions::Type_Order) {
        $out .= sprintf qq{<h2>%s</h2>\n}, $func_kind2jp{$type} || $Pod::Functions::Type_Description{$type} || $type;
        my $strlen = 0;
        foreach my $func (@{$Pod::Functions::Kinds{$type}}) {
            my $func_link = $func;
            $func_link =~ s{^(y|s|tr|m)///?$}{$1};
            $func_link =~ s{^(qq|qr)/STRING/$}{$1};
            if ($strlen > 40) {
                $out .= "<br />\n";
                $strlen = 0;
            }
            $out .= sprintf qq{ <a href="/func/%s">%s</a>,}, html_escape($func_link), html_escape($func);
            $strlen += length $func;
        }
        chop($out);
        $out .= "\n<br />\n";
    }
    mark_raw($out);
}

sub _render_function {
        my ($class) = @_;

        open my $fh, '<:utf8', 'toc-func.txt' or die "Cannot open toc-func.txt: $!";
        my $out;
        while (<$fh>) {
                chomp;
                if (!/\S/) {
                        next;
                } elsif (/^\s*\#/) {
                        next; # comment line
                } elsif (/^\((.+)\)/) { # name
                        $out .= sprintf("<h2>%s</h2>\n", html_escape($1));
                } elsif (/^C</) { # link
                        my @outs;
                        my $line = $_;
                        while ($line =~ s/C<([^>]+)>//) {
                my ($url, $text) = ($1, $1);
                $url =~ s!/+$!!; # s/// みたいなやつは s にリンクするべき
                push @outs,
                  sprintf( '<a href="/func/%s">%s</a>', html_escape($url), html_escape($text) );
                        }
                        $out .= join(", ", @outs) . "<br />\n";
                }
        }
        mark_raw($out);
}

1;

