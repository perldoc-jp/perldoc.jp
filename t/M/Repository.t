use v5.38;
use utf8;
use Test2::V0;

use File::Temp qw/tempdir/;
use File::Path qw/make_path/;
use File::Basename qw/dirname/;
use Encode ();
use File::Find::Rule;
use Time::Piece;
use PJP::M::Repository;

use lib 't/lib';
use Test::FakeBin qw/fake_bin/;

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

    # ファイルの中身も名前も、git が扱うのはバイト列。テストのソースは
    # use utf8 なので、境界で明示的に UTF-8 へ寄せる
    sub write_file {
        my ($self, $path, $body) = @_;
        my $full = $self->dir . '/' . Encode::encode_utf8($path);
        File::Path::make_path(File::Basename::dirname($full));
        open my $fh, '>:raw', $full or die $!;
        print $fh Encode::encode_utf8($body);
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
        local $ENV{GIT_AUTHOR_NAME}    = Encode::encode_utf8($opts{author}) if $opts{author};
        $self->git('add', '-A');
        $self->git('commit', '-q', '-m', $message);
    }
}

# git log の異常終了を再現するため、正常な 1 コミット分を出力してから
# 指定の死に方をする git ラッパを作る (new_repo のセットアップは実 git で
# 済ませておくこと)
sub fake_git_bin {
    my ($tail) = @_;
    return fake_bin('git',
        q{printf '\001%s\t%s\n' '2025-06-01 12:00:00 +0900' 'Tester'},
        q{printf 'A\tdocs/modules/Foo-1.00/Foo.pod\n'},
        $tail,
    );
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

subtest 'commit_events が全コミットを git log の走査順 (新しい方が先頭) で列挙する' => sub {
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

    # 走査順 = コミット順の逆 (新しい方が先)。perlvar の方が後にコミット
    # されているので、日時が古くても先に列挙される
    my $events = PJP::M::Repository->commit_events($c);
    is [map { $_->{path} } @$events], [
        'docs/perl/5.6.1/perlvar.pod',
        'docs/perl/5.8.8/perlfunc.pod',
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

subtest '同一 path の日時が祖先順と矛盾したらビルドを止める' => sub {
    # 時計の遅れたマシンからの push は、祖先順で後のコミットに古い committer
    # date を残す。date は年の割当に使うため、矛盾した履歴から導出すると
    # 年内最終判定 (祖先順) と年の割当 (date) が食い違った統計になり、
    # 自動コミットで恒久化する
    my ($c, $r) = new_repo();
    $r->write_file('docs/modules/Foo-1.00/Foo.pod', "=head1 Foo\n");
    $r->commit_at('2025-06-01T12:00:00+0900', 'translate Foo');
    $r->write_file('docs/modules/Foo-1.00/Foo.pod', "=head1 Foo v2\n");
    $r->commit_at('2025-05-01T12:00:00+0900', 'update Foo with a skewed clock');

    like dies { PJP::M::Repository->commit_events($c) },
        qr{docs/modules/Foo-1\.00/Foo\.pod}, '該当する path を挙げて die する';
};

subtest '別 path 同士の日時の前後は矛盾ではない' => sub {
    # ブランチをまたぐと別 path のイベントの日時は走査順で前後しうる。
    # 単調性の要請は path ごと
    my ($c, $r) = new_repo();
    $r->write_file('docs/modules/Foo-1.00/Foo.pod', "=head1 Foo\n");
    $r->commit_at('2025-06-01T12:00:00+0900', 'translate Foo');
    $r->write_file('docs/modules/Bar-1.00/Bar.pod', "=head1 Bar\n");
    $r->commit_at('2025-05-01T12:00:00+0900', 'translate Bar with an older clock');

    ok lives { PJP::M::Repository->commit_events($c) }, 'die しない';
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

    like dies { PJP::M::Repository->assert_current_paths_observable($c, $events) },
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
    ok lives { PJP::M::Repository->assert_current_paths_observable($c, $events) },
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

subtest 'merge の衝突解決でだけ作られたファイルを検出してビルドを止める' => sub {
    # どちらの親にも無いファイルを merge の解決で作ると、merge コミットの
    # diff は出ないためイベントが 1 件も現れない。配信はされるのに年次統計と
    # feed から落ちる状態なので、気づけるように止める
    my ($c, $r) = new_repo();
    $r->write_file('docs/modules/Foo-1.00/Foo.pod', "=head1 Foo\n");
    $r->commit_at('2025-01-01T12:00:00+0900', 'translate Foo');

    $r->git('checkout', '-q', '-b', 'topic');
    $r->write_file('docs/modules/Foo-1.00/Foo.pod', "=head1 Foo topic\n");
    $r->commit_at('2025-02-01T12:00:00+0900', 'update Foo on topic');

    $r->git('checkout', '-q', '-');
    $r->write_file('docs/modules/Foo-1.00/Foo.pod', "=head1 Foo master\n");
    $r->commit_at('2025-03-01T12:00:00+0900', 'update Foo on master');

    # 衝突の解決ついでに、どちらの親にも無かったファイルを足す
    $r->merge_conflicting('topic');
    $r->write_file('docs/modules/Foo-1.00/Foo.pod', "=head1 Foo merged\n");
    $r->write_file('docs/modules/Baz-1.00/Baz.pod', "=head1 Baz\n");
    $r->commit_at('2025-04-01T12:00:00+0900', 'merge topic', author => 'merger');

    my $events = PJP::M::Repository->commit_events($c);
    ok !grep({ $_->{path} eq 'docs/modules/Baz-1.00/Baz.pod' } @$events),
        'merge でだけ作られた path のイベントは 1 件も無い';

    like dies { PJP::M::Repository->assert_current_paths_observable($c, $events) },
        qr{docs/modules/Baz-1\.00/Baz\.pod}, '該当する path を挙げて die する';
};

subtest '祖先より先に子孫が出る走査順で、時計のずれたコミットを検出する' => sub {
    # 分岐した 2 つの子のうち一方が親より古い時計でコミットされた履歴。
    # --date-order は祖先を子より先に出さないので、親は後から読まれ、
    # その時点で日時の逆転として検出できる
    my ($c, $r) = new_repo();
    $r->write_file('docs/modules/Foo-1.00/Foo.pod', "=head1 Foo\n");
    $r->commit_at('2025-06-01T12:00:00+0900', 'translate Foo');    # 親 (新しい日時)

    $r->git('checkout', '-q', '-b', 'topic');
    $r->write_file('docs/modules/Bar-1.00/Bar.pod', "=head1 Bar\n");
    $r->commit_at('2025-07-01T12:00:00+0900', 'translate Bar');    # 別 path の子

    $r->git('checkout', '-q', '-');
    $r->write_file('docs/modules/Foo-1.00/Foo.pod', "=head1 Foo v2\n");
    $r->commit_at('2025-01-01T12:00:00+0900', 'update Foo');       # 時計が巻き戻った子

    $r->git('merge', '-q', '--no-edit', 'topic');

    like dies { PJP::M::Repository->commit_events($c) },
        qr{docs/modules/Foo-1\.00/Foo\.pod.+later output.+earlier output}s,
        '同じ path の日時が走査順と矛盾したら die する';
};

subtest '未来日時のコミットでビルドを止める' => sub {
    my ($c, $r) = new_repo();
    $r->write_file('docs/modules/Foo-1.00/Foo.pod', "=head1 Foo\n");
    $r->commit_at('2026-06-01T12:00:00+0900', 'translate Foo');

    {
        # 誤差の範囲 (数分先) は通す
        local $PJP::M::Repository::NOW_EPOCH = _jst_epoch('2026-06-01 11:55:00');
        ok lives { PJP::M::Repository->commit_events($c) }, '数分先のずれは許容する';
    }
    {
        local $PJP::M::Repository::NOW_EPOCH = _jst_epoch('2026-05-01 12:00:00');
        like dies { PJP::M::Repository->commit_events($c) },
            qr/2026-06-01 12:00:00/, '1 か月先のコミットは die する';
    }
};

subtest '年をまたぐ未来日時は誤差の範囲でも止める' => sub {
    # 対象年は最新イベントの前年なので、年をまたいだ数分のずれでも
    # 対象年が 1 年進んで、再導出すべき年が seed 側へ凍結される
    my ($c, $r) = new_repo();
    $r->write_file('docs/modules/Foo-1.00/Foo.pod', "=head1 Foo\n");
    $r->commit_at('2027-01-01T00:03:00+0900', 'translate Foo');

    local $PJP::M::Repository::NOW_EPOCH = _jst_epoch('2026-12-31 23:55:00');
    like dies { PJP::M::Repository->commit_events($c) },
        qr/2027-01-01 00:03:00/, '年が変わる側のずれは slack の内側でも die する';
};

subtest 'C 形式でクォートされた path でビルドを止める' => sub {
    # タブや改行を含む path は core.quotepath=false でもクォートされる。
    # 黙って落とすと現ツリーとの突き合わせが静かにずれる
    my ($c) = new_repo();
    my $bin = fake_bin('git',
        q{printf '\001%s\t%s\n' '2025-06-01 12:00:00 +0900' 'Tester'},
        q{printf 'M\t"docs/modules/Foo-1.00/Foo\\\\tbar.pod"\n'},
    );
    local $ENV{PATH} = "$bin:$ENV{PATH}";

    like dies { PJP::M::Repository->commit_events($c) },
        qr/C-quoted path/, 'クォートされた path を挙げて die する';
};

subtest '不正な UTF-8 の path でビルドを止める' => sub {
    # 置換文字に倒すと、異なるバイト列の path が同じ文字列に潰れて
    # 別ファイルのイベントが混ざる
    my ($c) = new_repo();
    my $bin = fake_bin('git',
        q{printf '\001%s\t%s\n' '2025-06-01 12:00:00 +0900' 'Tester'},
        q{printf 'M\tdocs/modules/Foo-1.00/\377.pod\n'},
    );
    local $ENV{PATH} = "$bin:$ENV{PATH}";

    like dies { PJP::M::Repository->commit_events($c) },
        qr/utf-?8/i, '不正なバイト列で die する';
};

subtest '不正な UTF-8 の path は decode の時点で止まる' => sub {
    # git 由来と readdir 由来のどちらもこの写像を通る。置換文字に倒すと
    # 異なるバイト列が同じ path に潰れ、両方の入口が同じ誤りに揃うことで
    # 突き合わせの検査まで素通りしてしまう。
    # (readdir 側を実ファイルで再現するテストは置けない。macOS は不正な
    #  UTF-8 のファイル名の作成自体を拒否する)
    like dies { PJP::M::Repository::decode_path("docs/modules/Foo-1.00/\xff.pod") },
        qr/utf-?8/i, '不正なバイト列で die する';
    is PJP::M::Repository::decode_path("docs/articles/perl/\x{e6}\x{97}\x{a5}.md"),
        'docs/articles/perl/日.md', '正しい UTF-8 は文字列に写る';
};

subtest '正常な並行ブランチでは日時の逆転検査が誤発火しない' => sub {
    # --date-order は「祖先を子より先に出さない」だけで、並行ブランチどうしの
    # 前後は日時に依存する。健全な履歴で止まってしまわないことを固定する
    my ($c, $r) = new_repo();
    $r->write_file('docs/modules/Foo-1.00/Foo.pod', "=head1 Foo\n");
    $r->commit_at('2025-01-01T12:00:00+0900', 'translate Foo');

    $r->git('checkout', '-q', '-b', 'topic');
    $r->write_file('docs/modules/Bar-1.00/Bar.pod', "=head1 Bar\n");
    $r->commit_at('2025-02-01T12:00:00+0900', 'translate Bar');

    $r->git('checkout', '-q', '-');
    $r->write_file('docs/modules/Baz-1.00/Baz.pod', "=head1 Baz\n");
    $r->commit_at('2025-03-01T12:00:00+0900', 'translate Baz');
    $r->git('merge', '-q', '--no-edit', 'topic');

    ok lives { PJP::M::Repository->commit_events($c) },
        '並行して別の翻訳が進んだだけの履歴では止まらない';
};

subtest '非 ASCII の author 名とファイル名が文字列として扱われる' => sub {
    my ($c, $r) = new_repo();
    $r->write_file('docs/articles/perl/日本語.md', "# 日本語\n");
    $r->commit_at('2025-06-01T12:00:00+0900', 'translate', author => '翻訳者');

    my $events = PJP::M::Repository->commit_events($c);
    is $events->[0]{path}, 'docs/articles/perl/日本語.md', 'path が decode 済みの文字列で返る';
    is $events->[0]{author}, '翻訳者', 'author が decode 済みの文字列で返る';
    ok PJP::M::Repository->current_paths($c)->{'docs/articles/perl/日本語.md'},
        '現ツリー側も同じ文字列空間に写る';
};

subtest '配信されない path は live に数えない' => sub {
    # current_paths は「現行のサイトが取り込む範囲」= docs/ 配下。
    # リポジトリ直下の運用文書や manual/ は DB にも route にも無いので、
    # live に数えると recent feed が 404 の URL を載せることになる
    my ($c, $r) = new_repo();
    $r->write_file('docs/modules/Foo-1.00/Foo.pod', "=head1 Foo\n");
    $r->write_file('README.md', "# readme\n");
    $r->write_file('manual/faq.md', "# faq\n");
    $r->commit_at('2025-06-01T12:00:00+0900', 'translate Foo');

    is [sort keys %{ PJP::M::Repository->current_paths($c) }],
        ['docs/modules/Foo-1.00/Foo.pod'], 'docs/ 配下だけが列挙される';

    # どちらもイベントとしては現れる (manual/ は年次統計に載る) が、
    # live ではないので観測性の検査は通る
    my $events = PJP::M::Repository->commit_events($c);
    ok lives { PJP::M::Repository->assert_current_paths_observable($c, $events) },
        '直下の .md や manual/ があっても観測性の検査は誤発火しない';
};

subtest '旧構成のディレクトリが現ツリーに復活していたら止める' => sub {
    # 履歴上の modules/... は docs/modules/... に正規化されるので、現ツリーに
    # 旧配置が復活すると canonical path が現行配置と衝突する。旧配置は配信も
    # されないため、黙って通すと誤った帰属だけが残る
    for my $dir (qw/modules perl articles core/) {
        my ($c, $r) = new_repo();
        $r->write_file('docs/modules/Foo-1.00/Foo.pod', "=head1 Foo\n");
        $r->write_file("$dir/Foo-1.00/Foo.pod", "=head1 Foo old\n");
        $r->commit_at('2025-06-01T12:00:00+0900', 'add legacy layout');

        ok !PJP::M::Repository->current_paths($c)->{"docs/modules/$dir/Foo-1.00/Foo.pod"},
            "$dir/ は live に数えない";

        my $events = PJP::M::Repository->commit_events($c);
        like dies { PJP::M::Repository->assert_current_paths_observable($c, $events) },
            qr{pre-2023 layout}, "$dir/ の復活で die する";
    }
};

subtest '旧配置の削除イベントは従来どおり shadowed-deletion で止まる' => sub {
    # 旧配置のファイル自体は HEAD に無いので上の検査には掛からない。
    # canonical path の最新イベントが旧配置側の削除になり、現行配置の
    # ファイルが削除済みと誤判定される経路をこちらが止める
    my ($c, $r) = new_repo();
    $r->write_file('modules/Foo-1.00/Foo.pod', "=head1 Foo old\n");
    $r->commit_at('2025-01-01T12:00:00+0900', 'translate Foo (old layout)');

    $r->git('checkout', '-q', '-b', 'topic');
    $r->write_file('docs/modules/Foo-1.00/Foo.pod', "=head1 Foo\n");
    $r->commit_at('2025-02-01T12:00:00+0900', 'move Foo under docs');

    $r->git('checkout', '-q', '-');
    $r->unlink_file('modules/Foo-1.00/Foo.pod');
    $r->commit_at('2025-03-01T12:00:00+0900', 'remove old layout');
    $r->git('merge', '-q', '--no-edit', 'topic');

    ok !-e $r->dir . '/modules/Foo-1.00/Foo.pod', '旧配置は HEAD に残っていない';
    ok PJP::M::Repository->current_paths($c)->{'docs/modules/Foo-1.00/Foo.pod'},
        '現行配置は live';

    my $events = PJP::M::Repository->commit_events($c);
    like dies { PJP::M::Repository->assert_current_paths_observable($c, $events) },
        qr{newest event is a deletion}, '旧配置の削除が現行 path の最新イベントになったら die する';
};

# JST の壁時計を epoch に直す (テストから現在時刻を固定するため)
sub _jst_epoch {
    my ($wall) = @_;
    return Time::Piece->strptime($wall, '%Y-%m-%d %H:%M:%S')->epoch - 9 * 3600;
}

done_testing;
