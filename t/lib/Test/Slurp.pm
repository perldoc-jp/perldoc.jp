use v5.38;

# 生成物を読み戻すためのテスト用ヘルパ。
#
# PJP::Util::slurp には委譲しない。テスト対象と読み戻しに同じレイヤの
# バグがあると素通りしてしまう (アプリ側での利用を禁じるものではない)。
package Test::Slurp;
use Encode ();
use Exporter 'import';

our @EXPORT_OK = qw/slurp_bytes slurp_text/;

# 生バイト列をそのまま返す。encoding そのものを検査する箇所はこちらで読み、
# decode はテスト側で独立に行う
sub slurp_bytes {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "Cannot open $path: $!";
    my $body = do { local $/; <$fh> };
    close $fh or die "Cannot close $path: $!";
    return $body;
}

# UTF-8 として strict に decode した文字列を返す。不正なシーケンスは
# 置換文字に倒さず die する (別々のバイト列が同じ文字列に潰れると、
# 「両側が同じ誤りに潰れる」ことで検査が素通りする)
sub slurp_text {
    my ($path) = @_;
    return Encode::decode('UTF-8', slurp_bytes($path), Encode::FB_CROAK | Encode::LEAVE_SRC);
}

1;
