package PJP::Util;

use strict;
use warnings;
use feature qw(state);
use parent 'Exporter';

use Text::Markdown::Discount ();

our @EXPORT_OK = qw/slurp markdown_to_html read_command/;

# 外部コマンドを読み取りパイプで実行し、出力を 1 行ずつ $cb に渡す。
#
# 終了状態の検査までを含めて 1 箇所にまとめてある。読み取りループは、コマンドが
# 途中で死んで出力が切れたのか正常に終わったのかを EOF から区別できないため、
# ここで検査しないと不完全な出力を正常な結果として扱ってしまう。特にシグナル死は
# $? >> 8 が 0 になるので、終了コードだけを見ると成功と区別が付かない。
# 子の異常終了だけが原因なら close は $! を 0 にする (perldoc -f close)。
# list 形式の pipe open は exec 失敗を open 時点で検出できず、それもここで
# 顕在化する。
#
# ok_exit: 正常とみなす終了コードのリスト (既定 [0])。diff(1) のように
# 「差分あり」を非ゼロで返すコマンドのために開けてある。
sub read_command {
    my ($cmd, $cb, %opts) = @_;
    my %ok_exit = map { $_ => 1 } @{ $opts{ok_exit} // [0] };

    open my $fh, '-|', @$cmd or die "Cannot run $cmd->[0]: $!";
    while (my $line = <$fh>) {
        $cb->($line);
    }

    return if close $fh;

    my $desc = join ' ', @$cmd;
    die "Cannot read output from $desc: $!" if $!;
    die "$desc was killed by signal " . ($? & 127) if $? & 127;

    my $exit = $? >> 8;
    return if $ok_exit{$exit};
    die "$desc exited with status $exit";
}

sub slurp {
    if (@_==1) {
        my ($stuff) = @_;
        open my $fh, '<', $stuff or die "Cannot open file: $stuff";
        do { local $/; <$fh> };
    } else {
        die "not implemented yet.";
    }
}

sub markdown_to_html {
    my ($markdown) = @_;

    state $flag = Text::Markdown::Discount::MKD_NOHEADER
                | Text::Markdown::Discount::MKD_NOPANTS
                | 0x02000000 # MKD_FENCEDCODE
                ;

    my $html = Text::Markdown::Discount::markdown($markdown, $flag);

    # perldoc.jp 用の加工
    $html =~ s{^.*<(?:body)[^>]*>}{}si;
    $html =~ s{</(?:body)>.*$}{}si;
    $html =~ s{<!--\s+original(.*?)-->}{<div class="original">$1</div>}sg;

    return $html;
}

1;

