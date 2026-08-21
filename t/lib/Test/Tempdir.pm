use v5.38;

# 使い捨てのディレクトリへ移って回すためのテスト用ヘルパ。
#
# 生成物は cwd からの相対パスに書かれるものが多く、テストごとに
# 「tempdir を作る → chdir → 元へ戻す」を書き写していた。戻し忘れると
# 後続のテストが前のテストの一時ディレクトリで走る。
package Test::Tempdir;
use Cwd ();
use Exporter 'import';
use File::Temp qw/tempdir/;

our @EXPORT_OK = qw/in_tempdir/;

# in_tempdir(\&cb) — 使い捨てディレクトリへ移り、$cb->($dir) を呼ぶ。
# 戻りは例外の有無に関わらず保証する。
#
# オプション引数は取らない。必要な下準備 (mkdir 等) はコールバックの中で
# 書く方が、何がどの順で作られるかがテスト側で読める
sub in_tempdir {
    my ($cb) = @_;
    my $orig = Cwd::getcwd();
    my $dir  = tempdir(CLEANUP => 1);
    chdir $dir or die "Cannot chdir to $dir: $!";
    my $guard = Test::Tempdir::Guard->new(sub { chdir $orig or die "Cannot chdir to $orig: $!" });
    return $cb->($dir);
}

{
    package Test::Tempdir::Guard;
    sub new { my ($class, $cb) = @_; bless { cb => $cb }, $class }
    sub DESTROY { $_[0]->{cb}->() }
}

1;
