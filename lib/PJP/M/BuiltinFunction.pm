use strict;
use warnings;
use utf8;

package PJP::M::BuiltinFunction;
use PJP::M::Pod;
use Pod::Perldoc;
use Amon2::Declare;
use Regexp::Assemble;
use constant FUNCTION_LIST_FILE => 'functions.txt';
use PJP::Util qw/slurp write_file_atomic record_perldoc_failure/;

# perlop から検索するものの正規表現
my $OPS_REGEXP = 'tr|s|q|qq|y|m|qr|qx';


# パッケージ変数にしているのは、テストが local で退避してから
# _load_functions を呼べるようにするため (my だと local できない)
our @FUNCTIONS;
our %FUNCTIONS;
our @REGEXP;

# functions.txt は generate が書く生成物なので、クリーンビルドではモジュール
# ロード時にまだ存在しない。ロード時の 1 回だけで確定させると、同一プロセスで
# generate の後に走る PodFile->generate が空の @REGEXP を使い、perlfunc の
# HTML から組み込み関数へのリンクが黙って消える。generate の最後に呼び直せる
# よう sub に括り出してある
sub _load_functions {
    # 引数はテスト用。本番の呼び出し (ロード時と generate の最後) は
    # generate が書くのと同じ FUNCTION_LIST_FILE を見る
    my $file = shift // FUNCTION_LIST_FILE;

    @FUNCTIONS = -e $file ? sort split /\n/, slurp($file) : ();

    %FUNCTIONS = ();
    @FUNCTIONS{@FUNCTIONS} = ();

    @REGEXP = ();
    my $i = 0;
    my @func_re;
    foreach my $func (@FUNCTIONS) {
        push @func_re, $func;
        # to avoid warning 'Complex regular subexpression recursion limit (32766) exceeded'
        if (@func_re > 30) {
            my $ra = Regexp::Assemble->new;
            $ra->add(@func_re);
            $REGEXP[$i++] = $ra->as_string;
            @func_re = ();
        }
    }
    if (@func_re) {
        my $ra = Regexp::Assemble->new;
        $ra->add(@func_re);
        $REGEXP[$i] = $ra->as_string;
    }
    return;
}

_load_functions();

# perlfunc.pod の HTML に出てくる組み込み関数名を /func/* へのリンクにする。
# @REGEXP を所有しているのはこのパッケージなので、参照する側 (PodFile) に
# 正規表現の組み立てを持たせず、ここに置いて呼んでもらう
sub linkify_functions {
    my ($class, $html) = @_;
    foreach my $regexp (@REGEXP) {
        $html =~ s{<code>($regexp)</code>}{<code><a href="/func/$1" target="_blank">$1</a></code>}g;
    }
    # クォート系演算子は functions.txt には載らないので個別に拾う。
    # $OPS_REGEXP とは対象が違う (こちらは qw を含み、区切り文字を伴う形だけを見る)
    $html =~ s{<code>(qq|q|tr|y|m|s|qr|qw|qx)(///?)</code>}{<code><a href="/func/$1" target="_blank">$1$2</a></code>}g;
    return $html;
}

sub exists {
    my ($class, $name) = @_;
    return (exists $FUNCTIONS{$name} or $name =~ qr/^$OPS_REGEXP$/);
}

sub retrieve {
    my ($class, $name) = @_;
    c->dbh->selectrow_array(q{SELECT version, html FROM func WHERE name=?}, {}, $name);
}

sub generate {
    my ($class, $c) = @_;

    my $path_info = PJP::M::Pod->get_latest_file_path('perlfunc');
    my ($path, $version) = @$path_info;

    my $path_info_perlop = PJP::M::Pod->get_latest_file_path('perlop');
    my ($perlop_path, $perlop_version) = @$path_info_perlop;

    my ($perlfunc_encoding, @candidate) = do
        {
            my $_encoding;
            my @_candidate;
            open my $fh, '<', $path or die "Cannot open $path: $!";
            while (<$fh>) {
                $_encoding = $1 and next if !defined $_encoding && m{^=encoding\s+(.+)$};
                s{E<sol>}{/}g;
                my @names = m{C<(\-?[a-zA-Z0-9_]+)(?:[^>]+)?>}g;
                push @_candidate, map {s{^($OPS_REGEXP)(?:/+|/STRING/)$}{$1}; $_} @names;
            }
            close $fh;
            my %tmp;
            @tmp{@_candidate} = ();
            # keys の順は同じ入力でも実行ごとに変わる。この列がそのまま
            # functions.txt の行順と func テーブルの挿入順になるため、
            # 並べ替えないと生成物が非決定的になる
            ($_encoding, sort keys %tmp);
        };

    my $perlop_encoding = do
        {
            my $_encoding;
            open my $fh, '<', $perlop_path or die "cannot open $perlop_path: $!";
            while (<$fh>) {
                if (m{^=encoding\s+(.+)$}) {
                    $_encoding = $1;
                    last;
                }
            }
            close $fh;
            $_encoding;
        };

    $perlfunc_encoding ||= 'euc-jp';
    $perlop_encoding   ||= 'euc-jp';

    my (@functions, @failures);
    my $txn = $c->dbh_master->txn_scope();
    $c->dbh_master->do(q{DELETE FROM func});
    for my $name (@candidate) {
        my $encoding;
        my @dynamic_pod;
        my $perldoc = Pod::Perldoc->new(opt_f => $name);
        my $found_in_perlop = 0;
        if (not $name =~ m{^(?:$OPS_REGEXP)$}) {
            eval {
                $perldoc->search_perlfunc([$path, $perlop_path], \@dynamic_pod);
                1;
            } or record_perldoc_failure(\@failures, $name, $@);
            $encoding = $perlfunc_encoding;
        } else {
            eval {
                $perldoc->search_perlop([$perlop_path], \@dynamic_pod);
                1;
            } or record_perldoc_failure(\@failures, $name, $@);
            if (@dynamic_pod) {
                $found_in_perlop = 1;
                # search_perlop が search_perlfuncと挙動が違い、=over と =back の後を余計に拾ってしまう
                my ($start_index, $last_index) = (0, 0);
                for (my $i = 0; $i < @dynamic_pod; $i++) {
                    if ($dynamic_pod[$i] =~ m{^=over }) {
                        $start_index = $i;
                        last;
                    }
                }
                for (my $i = @dynamic_pod - 1; $i > $start_index; $i--) {
                    if ($dynamic_pod[$i] =~m{^\s*=back}) {
                        $last_index = $i;
                        last;
                    }
                }
                $encoding = $perlop_encoding;
                @dynamic_pod = @dynamic_pod[$start_index .. $last_index];
            }
        }
        next if not @dynamic_pod;

        push @functions, $name;
        my $pod = join("", "=encoding $encoding\n\n=over 4\n\n", @dynamic_pod, "\n\n=back\n");
        $pod =~ s!L</([a-z]+)>!L<$1|http://perldoc.jp/func/$1>!g;
        $pod =~ s!L<C<([a-z]+|__[A-Z]+__)(>\|/\1(?: .+?)?)>!L<$1|http://perldoc.jp/func/$1>!g;
        my $html = PJP::M::Pod->pod2html(\$pod);
        $c->dbh_master->insert(
                               func => {
                                        name    => $name,
                                        version => $found_in_perlop ? $perlop_version : $version,
                                        html    => $html,
                                       },
                              );
    }

    # DB の確定と functions.txt の差し替えより前に判定する。後に置くと、
    # 失敗したビルドが部分的な一覧を公開してしまう
    die "cannot look up these builtins:\n" . join('', map { "  $_\n" } @failures)
        if @failures;

    write_file_atomic(FUNCTION_LIST_FILE, sub { print {$_[0]} join "\n", @functions });
    $txn->commit();

    # 書いたばかりの一覧をこのプロセスに反映する。後続の PodFile->generate が
    # @REGEXP を使って perlfunc の関数名をリンクにするため、ここで読み直さないと
    # クリーンビルドのイメージだけリンクの無い HTML が焼き込まれる
    _load_functions();
}

1;
