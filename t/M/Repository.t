use v5.38;
use utf8;
use Test2::V0;

use File::Temp qw/tempdir/;
use File::Path qw/make_path/;
use File::Find::Rule;
use Time::Piece;
use PJP::M::Repository;

# assets_dir / mode_name だけを持つ最小のコンテキスト
{
    package Test::Context;
    sub new    { my ($class, %args) = @_; bless {%args}, $class }
    sub config { $_[0]->{config} }
    sub mode_name { 'test' }
}

my $tmp = tempdir(CLEANUP => 1);
my $assets = "$tmp/assets/";
my $repo   = "${assets}translation";
make_path("$repo/docs/modules/Foo-1.00");
make_path("$repo/docs/modules/Bar-1.00");

my $c = Test::Context->new(config => { assets_dir => $assets });

sub git { system('git', '-C', $repo, @_) == 0 or die "git @_ failed" }

sub commit_at {
    my ($date, $message) = @_;
    local $ENV{GIT_AUTHOR_DATE}    = $date;
    local $ENV{GIT_COMMITTER_DATE} = $date;
    git('add', '-A');
    git('commit', '-q', '-m', $message);
}

sub write_file {
    my ($path, $body) = @_;
    open my $fh, '>', $path or die $!;
    print $fh $body;
    close $fh;
}

git('init', '-q', '.');
git('config', 'user.email', 'tester@example.com');
git('config', 'user.name',  'Tester');

write_file("$repo/docs/modules/Foo-1.00/Foo.pod", "=head1 Foo\n");
write_file("$repo/docs/modules/Bar-1.00/Bar.pod", "=head1 Bar\n");
commit_at('2025-06-01T12:00:00+0900', 'translate Foo and Bar');

subtest 'current_paths が現ツリーの path を列挙する' => sub {
    my $paths = PJP::M::Repository->current_paths($c);
    is [sort keys %$paths], [
        'docs/modules/Bar-1.00/Bar.pod',
        'docs/modules/Foo-1.00/Foo.pod',
    ], '2 ファイルとも path 形式で列挙される';
};

subtest 'recent_data の path が current_paths と一致する' => sub {
    my $since   = Time::Piece->strptime('2025-01-01 00:00:00', '%Y-%m-%d %H:%M:%S');
    my $updates = PJP::M::Repository->recent_data($c, $since);
    my $paths   = PJP::M::Repository->current_paths($c);
    ok scalar(@$updates), 'エントリが取れる';
    for my $u (@$updates) {
        ok $paths->{$u->{path}}, "recent_data の path が current_paths にある: $u->{path}";
    }
};

subtest '削除された翻訳は current_paths から消える' => sub {
    # Bar を翌年に削除する。git 履歴には残るが checkout からは消えるので
    # recent_data は列挙しない = 前年の統計から落ちる入力になる
    unlink "$repo/docs/modules/Bar-1.00/Bar.pod" or die $!;
    commit_at('2026-03-01T12:00:00+0900', 'remove Bar');

    my $paths = PJP::M::Repository->current_paths($c);
    ok !$paths->{'docs/modules/Bar-1.00/Bar.pod'}, '削除された path は含まれない';
    ok $paths->{'docs/modules/Foo-1.00/Foo.pod'},  '残っている path は含まれる';

    my $since   = Time::Piece->strptime('2025-01-01 00:00:00', '%Y-%m-%d %H:%M:%S');
    my $until   = Time::Piece->strptime('2026-01-01 00:00:00', '%Y-%m-%d %H:%M:%S');
    my $updates = PJP::M::Repository->recent_data($c, $since, $until);
    is [map { $_->{path} } @$updates], ['docs/modules/Foo-1.00/Foo.pod'],
        '2025 年窓の再導出からは削除済みのものが落ちる (seed 保持が必要な理由)';
};

subtest 'rename された翻訳も旧 path は current_paths から消える' => sub {
    rename "$repo/docs/modules/Foo-1.00", "$repo/docs/modules/Foo-2.00" or die $!;
    commit_at('2026-04-01T12:00:00+0900', 'rename Foo');

    my $paths = PJP::M::Repository->current_paths($c);
    ok !$paths->{'docs/modules/Foo-1.00/Foo.pod'}, '旧 path は含まれない';
    ok $paths->{'docs/modules/Foo-2.00/Foo.pod'},  '新 path が含まれる';
};

done_testing;
