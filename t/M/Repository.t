use v5.38;
use utf8;
use Test2::V0;

use File::Temp qw/tempdir/;
use File::Path qw/make_path/;
use File::Basename qw/dirname/;
use File::Find::Rule;
use Time::Piece;
use PJP::M::Repository;

# assets_dir / mode_name だけを持つ最小のコンテキスト
{
    package Test::Context;
    sub new       { my ($class, %args) = @_; bless {%args}, $class }
    sub config    { $_[0]->{config} }
    sub mode_name { 'test' }
}

# サブテストごとに使い捨ての translation リポジトリを作る。
# 削除や rename を伴うので、1 つのリポジトリを共有すると
# サブテストの実行順に依存してしまう
sub new_repo {
    my $assets = tempdir(CLEANUP => 1) . '/assets/';
    my $repo   = "${assets}translation";
    make_path($repo);

    my $r = Test::Repo->new(dir => $repo);
    $r->git('init', '-q', '.');
    $r->git('config', 'user.email', 'tester@example.com');
    $r->git('config', 'user.name',  'Tester');
    return (Test::Context->new(config => { assets_dir => $assets }), $r);
}

{
    package Test::Repo;
    sub new { my ($class, %args) = @_; bless {%args}, $class }
    sub dir { $_[0]->{dir} }

    sub git {
        my ($self, @args) = @_;
        system('git', '-C', $self->dir, @args) == 0 or die "git @args failed";
    }

    sub write_file {
        my ($self, $path, $body) = @_;
        my $full = $self->dir . "/$path";
        File::Path::make_path(File::Basename::dirname($full));
        open my $fh, '>', $full or die $!;
        print $fh $body;
        close $fh;
    }

    sub unlink_file {
        my ($self, $path) = @_;
        unlink $self->dir . "/$path" or die $!;
    }

    sub rename_dir {
        my ($self, $from, $to) = @_;
        rename $self->dir . "/$from", $self->dir . "/$to" or die $!;
    }

    # コミット日時は GIT_*_DATE で固定する。local なので他のテストに漏れない
    sub commit_at {
        my ($self, $date, $message) = @_;
        local $ENV{GIT_AUTHOR_DATE}    = $date;
        local $ENV{GIT_COMMITTER_DATE} = $date;
        $self->git('add', '-A');
        $self->git('commit', '-q', '-m', $message);
    }
}

sub jst { Time::Piece->strptime($_[0], '%Y-%m-%d %H:%M:%S') }

subtest 'current_paths が現ツリーの path を列挙する' => sub {
    my ($c, $r) = new_repo();
    $r->write_file('docs/modules/Foo-1.00/Foo.pod', "=head1 Foo\n");
    $r->write_file('docs/modules/Bar-1.00/Bar.pod', "=head1 Bar\n");
    $r->commit_at('2025-06-01T12:00:00+0900', 'translate Foo and Bar');

    is [sort keys %{ PJP::M::Repository->current_paths($c) }], [
        'docs/modules/Bar-1.00/Bar.pod',
        'docs/modules/Foo-1.00/Foo.pod',
    ], '2 ファイルとも path 形式で列挙される';
};

subtest 'recent_data の path が current_paths と一致する' => sub {
    my ($c, $r) = new_repo();
    $r->write_file('docs/modules/Foo-1.00/Foo.pod', "=head1 Foo\n");
    $r->write_file('docs/modules/Bar-1.00/Bar.pod', "=head1 Bar\n");
    $r->commit_at('2025-06-01T12:00:00+0900', 'translate Foo and Bar');

    my $updates = PJP::M::Repository->recent_data($c, jst('2025-01-01 00:00:00'));
    my $paths   = PJP::M::Repository->current_paths($c);
    ok scalar(@$updates), 'エントリが取れる';
    for my $u (@$updates) {
        ok $paths->{$u->{path}}, "recent_data の path が current_paths にある: $u->{path}";
    }
};

subtest '削除された翻訳は current_paths からも再導出からも消える' => sub {
    my ($c, $r) = new_repo();
    $r->write_file('docs/modules/Foo-1.00/Foo.pod', "=head1 Foo\n");
    $r->write_file('docs/modules/Bar-1.00/Bar.pod', "=head1 Bar\n");
    $r->commit_at('2025-06-01T12:00:00+0900', 'translate Foo and Bar');

    # Bar を翌年に削除する。git 履歴には残るが checkout からは消えるので
    # recent_data は列挙しない = 前年の統計から落ちる入力になる
    $r->unlink_file('docs/modules/Bar-1.00/Bar.pod');
    $r->commit_at('2026-03-01T12:00:00+0900', 'remove Bar');

    my $paths = PJP::M::Repository->current_paths($c);
    ok !$paths->{'docs/modules/Bar-1.00/Bar.pod'}, '削除された path は含まれない';
    ok $paths->{'docs/modules/Foo-1.00/Foo.pod'},  '残っている path は含まれる';

    my $updates = PJP::M::Repository->recent_data(
        $c, jst('2025-01-01 00:00:00'), jst('2026-01-01 00:00:00'));
    is [map { $_->{path} } @$updates], ['docs/modules/Foo-1.00/Foo.pod'],
        '2025 年窓の再導出からは削除済みのものが落ちる (seed 保持が必要な理由)';
};

subtest 'rename された翻訳も旧 path は current_paths から消える' => sub {
    my ($c, $r) = new_repo();
    $r->write_file('docs/modules/Foo-1.00/Foo.pod', "=head1 Foo\n");
    $r->commit_at('2025-06-01T12:00:00+0900', 'translate Foo');

    $r->rename_dir('docs/modules/Foo-1.00', 'docs/modules/Foo-2.00');
    $r->commit_at('2026-04-01T12:00:00+0900', 'rename Foo');

    my $paths = PJP::M::Repository->current_paths($c);
    ok !$paths->{'docs/modules/Foo-1.00/Foo.pod'}, '旧 path は含まれない';
    ok $paths->{'docs/modules/Foo-2.00/Foo.pod'},  '新 path が含まれる';
};

subtest '--date=iso-local が committer のオフセットを TZ に揃える' => sub {
    # 負のオフセットのコミット。--date=iso のままだと壁時計が 00:00:00 のまま
    # 出て、JST の 16:00:00 と 16 時間ずれる
    local $ENV{TZ} = 'Asia/Tokyo';
    my ($c, $r) = new_repo();
    $r->write_file('docs/modules/Baz-1.00/Baz.pod', "=head1 Baz\n");
    $r->commit_at('2026-06-15T00:00:00-0700', 'translate Baz from another timezone');

    my $updates = PJP::M::Repository->recent_data($c, jst('2026-01-01 00:00:00'));
    my ($baz)   = grep { $_->{path} eq 'docs/modules/Baz-1.00/Baz.pod' } @$updates;
    ok $baz, 'Baz のエントリが取れる';
    is $baz->{date}, '2026-06-15 16:00:00', 'JST に変換された壁時計で記録される';
};

subtest '年境界のコミットが 2 つの窓に二重に入らない' => sub {
    # git の --since / --until は両端を含むので、create_year_data.pl が使う
    # 2 窓を [since, until) と [until, ) の半開区間にしないと、元日 00:00:00
    # ちょうどのコミットが両方に出て commit_count_all が二重加算される
    local $ENV{TZ} = 'Asia/Tokyo';
    my ($c, $r) = new_repo();
    $r->write_file('docs/modules/Boundary-1.00/Boundary.pod', "=head1 Boundary\n");
    $r->commit_at('2027-01-01T00:00:00+0900', 'commit exactly at the year boundary');

    my $since = jst('2026-01-01 00:00:00');
    my $until = jst('2027-01-01 00:00:00');
    my $path  = 'docs/modules/Boundary-1.00/Boundary.pod';

    my $after  = PJP::M::Repository->recent_data($c, $until);
    my $closed = PJP::M::Repository->recent_data($c, $since, $until);
    is scalar(grep { $_->{path} eq $path } @$closed, @$after), 2,
        '両端を含む窓では境界のコミットが 2 回現れる (これが二重加算の入力)';

    my $half = PJP::M::Repository->recent_data($c, $since, $until - 1);
    is scalar(grep { $_->{path} eq $path } @$half, @$after), 1,
        '半開区間なら 1 回だけ現れる';
};

done_testing;
