use v5.38;

# 外部コマンドを差し替えるためのテスト用ヘルパ。
#
# read_command を通す経路 (git log / diff) は、コマンドの異常終了や想定外の
# 出力に対する振る舞いを検証したい。実物では再現できないので、同名の sh
# スクリプトを置いたディレクトリを作り、呼び出し側が PATH の先頭に差し込む。
package Test::FakeBin;
use Exporter 'import';
use File::Temp qw/tempdir/;

our @EXPORT_OK = qw/fake_bin/;

# fake_bin($name, @lines) — sh スクリプトを作り、その置き場所を返す。
# @lines はそのまま本体になるので、出力も死に方も呼び出し側が決める
sub fake_bin {
    my ($name, @lines) = @_;

    my $bin = tempdir(CLEANUP => 1);
    open my $fh, '>', "$bin/$name" or die "Cannot create $bin/$name: $!";
    print $fh "#!/bin/sh\n", map { "$_\n" } @lines;
    close $fh or die "Cannot write $bin/$name: $!";
    chmod 0755, "$bin/$name" or die "Cannot chmod $bin/$name: $!";
    return $bin;
}

1;
