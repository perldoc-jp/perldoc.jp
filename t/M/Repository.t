use v5.38;
use utf8;
use Test2::V0;

use File::Temp qw/tempdir/;
use File::Path qw/make_path/;
use File::Basename qw/dirname/;
use File::Find::Rule;
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
        my ($self, $date, $message, %opts) = @_;
        local $ENV{GIT_AUTHOR_DATE}    = $date;
        local $ENV{GIT_COMMITTER_DATE} = $date;
        local $ENV{GIT_AUTHOR_NAME}    = $opts{author} if $opts{author};
        $self->git('add', '-A');
        $self->git('commit', '-q', '-m', $message);
    }
}

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

subtest 'commit_events が全コミットを日付の降順で列挙する' => sub {
    local $ENV{TZ} = 'Asia/Tokyo';
    my ($c, $r) = new_repo();
    $r->write_file('docs/modules/Foo-1.00/Foo.pod', "=head1 Foo\n");
    $r->commit_at('2025-06-01T12:00:00+0900', 'translate Foo');
    $r->write_file('docs/modules/Foo-1.00/Foo.pod', "=head1 Foo v2\n");
    $r->commit_at('2025-07-01T12:00:00+0900', 'update Foo');

    my $events = PJP::M::Repository->commit_events($c);
    is [map { [ @$_{qw/date path/} ] } @$events], [
        ['2025-07-01 12:00:00', 'docs/modules/Foo-1.00/Foo.pod'],
        ['2025-06-01 12:00:00', 'docs/modules/Foo-1.00/Foo.pod'],
    ], '同じファイルの複数コミットがすべてイベントになる';

    my $paths = PJP::M::Repository->current_paths($c);
    ok $paths->{$_->{path}}, "path 形式が current_paths と一致する: $_->{path}"
        for @$events;
};

subtest '削除・rename された翻訳のイベントも含まれる' => sub {
    local $ENV{TZ} = 'Asia/Tokyo';
    my ($c, $r) = new_repo();
    $r->write_file('docs/modules/Foo-1.00/Foo.pod', "=head1 Foo\n");
    $r->write_file('docs/modules/Bar-1.00/Bar.pod', "=head1 Bar\n");
    $r->commit_at('2025-06-01T12:00:00+0900', 'translate Foo and Bar');

    # Bar を翌年に削除する。checkout からは消えるが、2025 年の翻訳イベントは
    # git 履歴から引き続き導出できなければならない (年次統計の欠落防止)
    $r->unlink_file('docs/modules/Bar-1.00/Bar.pod');
    $r->commit_at('2026-03-01T12:00:00+0900', 'remove Bar');

    my $events = PJP::M::Repository->commit_events($c);
    my ($translated) = grep { $_->{path} eq 'docs/modules/Bar-1.00/Bar.pod' and not $_->{deleted} } @$events;
    is $translated->{date}, '2025-06-01 12:00:00', '削除前の翻訳イベントが残る';

    my ($removed) = grep { $_->{deleted} } @$events;
    is [ @$removed{qw/date path/} ], ['2026-03-01 12:00:00', 'docs/modules/Bar-1.00/Bar.pod'],
        '削除は deleted フラグ付きのイベントになる';

    ok !PJP::M::Repository->current_paths($c)->{'docs/modules/Bar-1.00/Bar.pod'},
        '現ツリーの列挙からは消えている';
};

subtest 'subtree merge 前の path が現在の構造に正規化される' => sub {
    local $ENV{TZ} = 'Asia/Tokyo';
    # 2023 年のリポジトリ再編より前のコミットは docs/ prefix を持たない
    # (perl コア文書は perl/、旧 perldoc.jp 由来は core/)
    my ($c, $r) = new_repo();
    $r->write_file('perl/5.8.8/perlfunc.pod', "=head1 perlfunc\n");
    $r->commit_at('2008-06-01T12:00:00+0900', 'translate perlfunc');
    $r->write_file('core/5.6.1/perlvar.pod', "=head1 perlvar\n");
    $r->commit_at('2004-06-01T12:00:00+0900', 'translate perlvar');
    $r->write_file('wiki/translation-tips.md', "# tips\n");
    $r->commit_at('2020-06-01T12:00:00+0900', 'add wiki page');

    my $events = PJP::M::Repository->commit_events($c);
    is [map { $_->{path} } @$events], [
        'docs/perl/5.8.8/perlfunc.pod',
        'docs/perl/5.6.1/perlvar.pod',
    ], 'perl/ と core/ は docs/perl/ に写像され、翻訳文書でない path は落ちる';
    is $events->[0]{in}, 'perl', '正規化後の path から name/in が導出される';
};

subtest '--date=iso-local が committer のオフセットを TZ に揃える' => sub {
    # 負のオフセットのコミット。--date=iso のままだと壁時計が 00:00:00 のまま
    # 出て、JST の 16:00:00 と 16 時間ずれる
    local $ENV{TZ} = 'Asia/Tokyo';
    my ($c, $r) = new_repo();
    $r->write_file('docs/modules/Baz-1.00/Baz.pod', "=head1 Baz\n");
    $r->commit_at('2026-06-15T00:00:00-0700', 'translate Baz from another timezone');

    my $events = PJP::M::Repository->commit_events($c);
    my ($baz)  = grep { $_->{path} eq 'docs/modules/Baz-1.00/Baz.pod' } @$events;
    ok $baz, 'Baz のエントリが取れる';
    is $baz->{date}, '2026-06-15 16:00:00', 'JST に変換された壁時計で記録される';
};

subtest 'author 名がイベントに入る' => sub {
    local $ENV{TZ} = 'Asia/Tokyo';
    my ($c, $r) = new_repo();
    $r->write_file('docs/modules/Foo-1.00/Foo.pod', "=head1 Foo\n");
    $r->commit_at('2025-06-01T12:00:00+0900', 'translate Foo', author => 'Some Translator');

    my $events = PJP::M::Repository->commit_events($c);
    is $events->[0]{author}, 'Some Translator', 'コミットの author が観測される';
};

done_testing;
