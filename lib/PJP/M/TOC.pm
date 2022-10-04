use strict;
use warnings;
use utf8;

package PJP::M::TOC;
use Text::Xslate::Util qw/html_escape mark_raw/;
use File::stat;
use Log::Minimal;
use Pod::Functions;
use HTML::Entities qw/encode_entities/;

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
    my $pre_len = 4;
    while (<$fh>) {
        chomp;
        if (/^\s*$/) {
            $out =~ s{(.+)</li>}{$1<br><br></li>}s if $started;  # empty line
            next;
        } elsif (/^\s*\#/) {
            next;                       # comment line
        } elsif (/^\S/) {               # header line
            if ($pre_len >= 8) {
                $out .= "</ul>\n";
                $pre_len = 4;
            }
            $out .= "</ul>" if $started++;
            $out .= sprintf("<h3>%s</h3><ul>\n", html_escape($_));
        } else {                        # main line
            my $len = 0;
            if (s/^(\s+)//) {
                $len = length($1);
            }

            my ($pkg, $desc) = split /\s*-\s*/, $_, 2;
            if ($len >= 8 and $pre_len != $len) {
                $out .= "<ul>\n";
            } elsif ($len == 4 and $pre_len >= 8) {
                $out .= "</ul>";
            }
            $out .= sprintf('<li><a href="/pod/%s">%s</a>', (html_escape($pkg)) x 2);
            if ($desc) {
                $out .= sprintf(' - %s', html_escape($desc));
            }
            $out .= "</li>\n";
            $pre_len = $len;
        }
    }
    if ($pre_len >= 8) {
       $out .= "</ul>\n";
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
            $func_link =~ s{^(q|qq|qr)/STRING/$}{$1};
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

my %var_comment2jp = (
                      'The ground of all being. @ARG is deprecated (5.005 makes @_ lexical)'
                      => '引数',
                      'Matching.'                     => 'マッチング',
                      'Input.'                        => '入力',
                      'Output.'                       => '出力',
                      'Interpolation "constants".'    => '補完定数',
                      'Formats'                       => 'フォーマット',
                      'Error status.'                 => 'エラーステータス',
                      'Process info.'                 => 'プロセス情報',
                      'Internals.'                    => '内部変数',
                      'Deprecated.'                   => '廃止',
                     );

my %SKIP_NAME = (
                 '@' => {'+' => 0},
                );
my %ENG_NAME;

sub render_variable {
    my ($class, $c) = @_;
    my $out = '';
    my $pod;
    open my $fh, '<:utf8', 'toc-var.txt' or die "Cannot open toc-var.txt: $!";
    local $/;
    $pod = <$fh>;
    close $fh;

    my %already_done;

  LINE:
    while ($pod) {
        $pod =~ s{^(.*?)\n}{}s;
        my $line = $1;

        next if not $line or $line =~ m{^\s+#};

        if ($line =~ m{^# (.+)}) {
            my $title;
            $title = $var_comment2jp{$1} || $1;
            $out .= "</ul>\n"  if $out;

            $out .= "<h2>$title</h2>\n";
            $out .= "<ul>\n";
        } elsif ($line =~ m{^\s*\*([^\s]+)\s+=\s+([\*\$%@])([^\s]+)\s*;}s) {
            my ($english_name, $_sigil, $name) = ($1, $2, $3);
            my @alias;
            push @alias, $english_name if $english_name ne 'dummy_name';

            while ($pod =~ m{^ {10}\s*\*([^\s]+)\s+=\s+[\*\$%@]([^\s]+)\s*; *}s) {
                my ($english_name, $name) = ($1, $2, $3);
                $pod =~ s{^(.*?)\n}{}s;
                push @alias, $english_name;
            }
            foreach my $sigil ($name =~s{\{ARRAY\}}{} ?  ('@') : $_sigil ne '*' ? ($_sigil) :('$','@','%')) {
                next LINE if exists $SKIP_NAME{$sigil}{$name} and not $SKIP_NAME{$sigil}{$name}++;
                next LINE if $already_done{$sigil. $name}++;

                if (PJP::M::BuiltinVariable->exists($sigil . $name)) {
                    $out .= sprintf '<li><a href="/variable/%s">%s</a>', URI::Escape::uri_escape($sigil . $name), encode_entities($sigil . $name);
                    $out .= ' ... '  if @alias;
                    foreach my $alias (@alias) {
                        if ($ENG_NAME{$sigil}{$alias}) {
                            $out .= encode_entities(" ${sigil}$ENG_NAME{$sigil}{$alias},");
                        } elsif (PJP::M::BuiltinVariable->exists($sigil . $alias)) {
                            $out .= encode_entities(" $sigil$alias,");
                        }
                    }
                    $out =~s{,$}{};
                    $out .= "</li>\n";
                }
            }
        } else {
            die "--$line--";
        }
    }
    mark_raw($out);
}

1;
