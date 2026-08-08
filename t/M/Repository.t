use v5.38;
use utf8;
use Test2::V0;

use File::Temp qw/tempdir/;
use File::Path qw/make_path/;
use File::Basename qw/dirname/;
use File::Find::Rule;
use PJP::M::Repository;

# PJP::M::Repository が使う PJP のインターフェイスだけを持つ最小のコンテキスト
{
    package Test::Context;
    sub new        { my ($class, %args) = @_; bless {%args}, $class }
    sub config     { $_[0]->{config} }
    sub assets_dir { $_[0]->config->{assets_dir} // die "Missing configuration for assets dir" }
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

    # 衝突するのが前提の merge。終了コードは見ず、出力もテストログに混ぜない
    sub merge_conflicting {
        my ($self, $branch) = @_;
        my $dir = $self->dir;
        qx{git -C \Q$dir\E merge --no-edit --no-commit \Q$branch\E 2>&1};
        return;
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

# git log の異常終了を再現するため、正常な 1 コミット分を出力してから
# 指定の死に方をする git ラッパを作り、その置き場所を返す。呼び出し側が
# PATH の先頭に差し込む (new_repo のセットアップは実 git で済ませておくこと)
sub fake_git_bin {
    my ($tail) = @_;
    my $bin = tempdir(CLEANUP => 1);
    open my $fh, '>', "$bin/git" or die $!;
    print $fh "#!/bin/sh\n";
    print $fh "printf '\\001%s\\t%s\\n' '2025-06-01 12:00:00 +0900' 'Tester'\n";
    print $fh "printf 'A\\tdocs/modules/Foo-1.00/Foo.pod\\n'\n";
    print $fh "$tail\n";
    close $fh;
    chmod 0755, "$bin/git" or die $!;
    return $bin;
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

subtest '現存する path の名前が導出できなければビルドを止める' => sub {
    # docs/ 配下 = 翻訳文書ツリーを名乗っているのに配置規則に合わない path。
    # 黙って落とすと、配信はされるのに年次統計と recent feed から欠落し、
    # data/years.pl の自動コミットで欠落が恒久化するため、現ツリーに存在する
    # 間はビルドを止めて配置規則側の追従を促す
    my ($c, $r) = new_repo();
    $r->write_file('docs/modules/NoVersion/lib/Foo.pod', "=head1 Foo\n");
    $r->commit_at('2025-06-01T12:00:00+0900', 'add unversioned dist dir');

    like dies { PJP::M::Repository->commit_events($c) },
        qr{docs/modules/NoVersion/lib/Foo\.pod}, '該当する path を挙げて die する';
};

subtest '履歴にだけ残る未知の形状の path はイベントにしない' => sub {
    # 過去に存在した非文書ファイルや旧構成の path は名前が導出できなくてよい。
    # 現ツリーに無ければ配信も統計対象も無いので、ビルドは止めず黙って落とす
    my ($c, $r) = new_repo();
    $r->write_file('docs/modules/NoVersion/lib/Foo.pod', "=head1 Foo\n");
    $r->write_file('docs/modules/Bar-1.00/Bar.pod', "=head1 Bar\n");
    $r->commit_at('2025-06-01T12:00:00+0900', 'add unversioned dist dir');
    $r->unlink_file('docs/modules/NoVersion/lib/Foo.pod');
    $r->commit_at('2025-07-01T12:00:00+0900', 'remove unversioned dist dir');

    my $events;
    ok lives { $events = PJP::M::Repository->commit_events($c) },
        '削除済みなら die しない';
    is [map { $_->{path} } @$events], ['docs/modules/Bar-1.00/Bar.pod'],
        '名前が導出できない path はイベントにならない';
};

subtest '日付の TZ は呼び出し元の環境に依存しない' => sub {
    # 負のオフセットのコミット。--date=iso のままだと壁時計が 00:00:00 のまま
    # 出て、JST の 16:00:00 と 16 時間ずれる。
    # 周囲の TZ を JST 以外にしても JST で観測されること = commit_events が
    # 日付の解釈を所有していること。ここが壊れると、docs/cloud-run.md が案内する
    # 手元での再導出を非 JST のマシンで実行しただけで年境界のコミットが別の年に
    # 落ち、その data/years.pl が seed として恒久化する
    local $ENV{TZ} = 'America/Los_Angeles';
    my ($c, $r) = new_repo();
    $r->write_file('docs/modules/Baz-1.00/Baz.pod', "=head1 Baz\n");
    $r->commit_at('2026-06-15T00:00:00-0700', 'translate Baz from another timezone');

    my $events = PJP::M::Repository->commit_events($c);
    my ($baz)  = grep { $_->{path} eq 'docs/modules/Baz-1.00/Baz.pod' } @$events;
    ok $baz, 'Baz のエントリが取れる';
    is $baz->{date}, '2026-06-15 16:00:00', 'JST に変換された壁時計で記録される';
    is $ENV{TZ}, 'America/Los_Angeles', '呼び出し元の TZ を書き換えたままにしない';
};

subtest '年境界のコミットが JST の年に落ちる' => sub {
    # JST 元旦 00:00〜09:00 のコミット。UTC 解釈だと前年扱いになり、年次統計の
    # 集計年と create_year_data.pl が導出する対象年の両方がずれる
    local $ENV{TZ} = 'UTC';
    my ($c, $r) = new_repo();
    $r->write_file('docs/modules/Qux-1.00/Qux.pod', "=head1 Qux\n");
    $r->commit_at('2026-01-01T05:00:00+0900', 'translate Qux on new year morning');

    my $events = PJP::M::Repository->commit_events($c);
    is $events->[0]{date}, '2026-01-01 05:00:00', '前年 (2025-12-31) に落ちない';
};

subtest 'author 名がイベントに入る' => sub {
    my ($c, $r) = new_repo();
    $r->write_file('docs/modules/Foo-1.00/Foo.pod', "=head1 Foo\n");
    $r->commit_at('2025-06-01T12:00:00+0900', 'translate Foo', author => 'Some Translator');

    my $events = PJP::M::Repository->commit_events($c);
    is $events->[0]{author}, 'Some Translator', 'コミットの author が観測される';
};

subtest '同秒の追加と削除は git のコミット順で返る (author 名に依存しない)' => sub {
    # 同じ秒に「追加 → 削除」の 2 コミット。同秒・同 path では git log の
    # 出力順だけが真の前後関係を運ぶ。author 等の無関係なキーで並べ替えると
    # 名前の組み合わせ次第で削除が古い側に落ち、削除済みの翻訳が年次統計に
    # 生き残る
    for my $authors ([qw/zzz-adder aaa-remover/], [qw/aaa-adder zzz-remover/]) {
        my ($adder, $remover) = @$authors;
        my ($c, $r) = new_repo();
        $r->write_file('docs/modules/Foo-1.00/Foo.pod', "=head1 Foo\n");
        $r->commit_at('2025-06-01T12:00:00+0900', 'translate Foo', author => $adder);
        $r->unlink_file('docs/modules/Foo-1.00/Foo.pod');
        $r->commit_at('2025-06-01T12:00:00+0900', 'remove Foo', author => $remover);

        my $events = PJP::M::Repository->commit_events($c);
        is [map { [ $_->{deleted} ? 'D' : 'A', $_->{author} ] } @$events],
            [['D', $remover], ['A', $adder]],
            "削除が新しい側に来る ($adder → $remover)";
    }
};

subtest 'merge で復活した翻訳を検出してビルドを止める' => sub {
    # master での削除より前から分岐したブランチの merge がファイルを復活させると、
    # merge コミット自体は --name-status に何も出さないため、その path の最新
    # イベントは過去の削除のままになる。この矛盾を放置すると、生きている翻訳が
    # 年次統計から落ち、feed に削除者の名前で載り、それが seed に恒久化する
    my ($c, $r) = new_repo();
    $r->write_file('docs/modules/Foo-1.00/Foo.pod', "=head1 Foo\n");
    $r->commit_at('2025-01-01T12:00:00+0900', 'translate Foo');

    $r->git('checkout', '-q', '-b', 'topic');
    $r->write_file('docs/modules/Foo-1.00/Foo.pod', "=head1 Foo v2\n");
    $r->commit_at('2025-02-01T12:00:00+0900', 'update Foo', author => 'translator');

    $r->git('checkout', '-q', '-');
    $r->unlink_file('docs/modules/Foo-1.00/Foo.pod');
    $r->commit_at('2025-03-01T12:00:00+0900', 'remove Foo', author => 'remover');

    # modify/delete の衝突を「残す」で解決して merge する
    $r->merge_conflicting('topic');
    $r->write_file('docs/modules/Foo-1.00/Foo.pod', "=head1 Foo v2\n");
    $r->commit_at('2025-04-01T12:00:00+0900', 'merge topic', author => 'merger');

    my $events = PJP::M::Repository->commit_events($c);
    my ($newest) = grep { $_->{path} eq 'docs/modules/Foo-1.00/Foo.pod' } @$events;
    ok $newest->{deleted}, '最新イベントは削除のまま (merge の diff は出ない)';
    ok PJP::M::Repository->current_paths($c)->{'docs/modules/Foo-1.00/Foo.pod'},
        'ファイルは現ツリーに存在する';

    like dies { PJP::M::Repository->assert_no_shadowed_deletions($c, $events) },
        qr{docs/modules/Foo-1\.00/Foo\.pod}, '該当する path を挙げて die する';
};

subtest '通常の削除や現存する翻訳では止まらない' => sub {
    my ($c, $r) = new_repo();
    $r->write_file('docs/modules/Foo-1.00/Foo.pod', "=head1 Foo\n");
    $r->write_file('docs/modules/Bar-1.00/Bar.pod', "=head1 Bar\n");
    $r->commit_at('2025-06-01T12:00:00+0900', 'translate Foo and Bar');
    $r->unlink_file('docs/modules/Bar-1.00/Bar.pod');
    $r->commit_at('2026-03-01T12:00:00+0900', 'remove Bar');

    my $events = PJP::M::Repository->commit_events($c);
    ok lives { PJP::M::Repository->assert_no_shadowed_deletions($c, $events) },
        '現ツリーから消えている path の削除イベントは矛盾ではない';
};

subtest 'git log が途中で失敗したらビルドを止める' => sub {
    # 部分出力のまま EOF になっても、正常終了と区別して die しなければ
    # ならない (不完全なイベント列は自動コミットで master に恒久化するため)
    my ($c) = new_repo();
    my $bin = fake_git_bin('exit 3');
    local $ENV{PATH} = "$bin:$ENV{PATH}";
    like dies { PJP::M::Repository->commit_events($c) },
        qr/git .+ exited with status 3/,
        '部分出力の後の異常終了で die する';
};

subtest 'git log がシグナルで死んでもビルドを止める' => sub {
    my ($c) = new_repo();
    my $bin = fake_git_bin('kill -9 $$');
    local $ENV{PATH} = "$bin:$ENV{PATH}";
    like dies { PJP::M::Repository->commit_events($c) },
        qr/git .+ was killed by signal 9/,
        'シグナル死で die する';
};

done_testing;
