package PJP::Util;

use strict;
use warnings;
use feature qw(state);
use parent 'Exporter';

use File::Basename ();
use File::Temp ();
use POSIX ();
use Text::Markdown::Discount ();

our @EXPORT_OK = qw/slurp markdown_to_html read_command write_file_atomic record_perldoc_failure/;

# Pod::Perldoc の検索失敗を仕分ける。組み込み関数・変数の候補は pod の
# C<...> から拾った文字列なので、実際には関数でも変数でもないものが混ざる。
# Pod::Perldoc はそれを 2 通りの die で伝えるので、どちらも正常系として通し、
# それ以外 (ファイルが読めない等) は集めて呼び出し元に止めさせる
my $NOT_FOUND = qr{
    ^No\ documentation\ for\ perl\ (?:function|variable|FAQ\ keyword)  # 該当なし
  | does\ not\ look\ like\ a\ Perl\ variable                           # 変数の形ですらない
}x;

sub record_perldoc_failure {
    my ($failures, $name, $error) = @_;
    return if $error =~ $NOT_FOUND;
    push @$failures, "$name: $error";
    return;
}

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
    my $desc = join ' ', @$cmd;

    my $pid = open my $fh, '-|', @$cmd or die "Cannot run $cmd->[0]: $!";

    # 読み取り中に die した場合 (呼び出し元の alarm など) は、close の前に子を
    # 明示的に殺す。close は子の終了を待つので、まだ出力し続けている子が
    # 相手だとそこで止まり、タイムアウトが効かなくなる
    eval {
        while (my $line = <$fh>) {
            $cb->($line);
        }
        1;
    } or do {
        my $error = $@ || "died\n";
        _terminate_child($pid);
        close $fh;
        die $error;
    };

    return if close $fh;

    die "Cannot read output from $desc: $!" if $!;
    die "$desc was killed by signal " . ($? & 127) if $? & 127;

    my $exit = $? >> 8;
    return if $ok_exit{$exit};
    die "$desc exited with status $exit";
}

# TERM で止まらない子のために KILL まで進む。消費者 (git, diff) は孫を作らない
# ので、直接の子だけを相手にすれば close が待ち続けることはない
sub _terminate_child {
    my ($pid) = @_;

    kill 'TERM', $pid or return;
    for (1 .. 20) {    # 最大 1 秒
        return if waitpid($pid, POSIX::WNOHANG()) == $pid;
        select undef, undef, undef, 0.05;
    }
    kill 'KILL', $pid;
    waitpid $pid, 0;
}

# 生成物を書き出す。同じディレクトリの一時ファイルに書き切ってから rename する
# ことで、書き込み中の中断が既存のファイルを壊さないようにする。
# data/years.pl は git 管理下の唯一の年次統計の原本で、2011 年より前は履歴から
# 再現できない。運用手順は手元でこのスクリプトを直接実行することも案内している
# ため、原子性は「壊れても再ビルドすればよい」では済まない。
#
# 一時ファイル名は File::Temp に任せる (固定名だと、同じディレクトリで
# 並行実行したときに双方が同じ inode に書き、片方の rename 後にもう片方が
# 最終ファイルを書き換えられる)。途中で die した場合は File::Temp が
# デストラクタで消すので、残骸は残らない。
sub write_file_atomic {
    my ($path, $cb) = @_;

    my $tmp = File::Temp->new(
        DIR    => File::Basename::dirname($path),
        SUFFIX => '.tmp',
        UNLINK => 1,
    );
    $cb->($tmp);
    # print の失敗はハンドルにエラーとして残る。呼び出し側の print の返り値に
    # 頼ると、末尾が print でないコールバックを書いた瞬間に検査が抜けるため、
    # ハンドルの状態を直接見る (書き損じたまま rename すると、既存のファイルが
    # 不完全な内容で置き換わる)
    die "Cannot write $path: $!" if $tmp->error;
    $tmp->flush or die "Cannot write $path: $!";
    close $tmp or die "Cannot write $path: $!";

    chmod 0644, $tmp->filename or die "Cannot chmod $path: $!";
    rename $tmp->filename, $path or die "Cannot rename to $path: $!";
    # rename 済みなので、デストラクタに消させない
    $tmp->unlink_on_destroy(0);
    return;
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

