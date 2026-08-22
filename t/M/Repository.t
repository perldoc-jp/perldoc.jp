use v5.38;
use utf8;
use Test2::V0;

use File::Temp qw/tempdir/;
use File::Path qw/make_path/;
use File::Spec;
use File::Basename qw/dirname/;
use Encode ();
use File::Find::Rule;
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
    File::Path::make_path($repo);

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

subtest '配置規則に合わない path はイベントにしない' => sub {
    my ($c, $r) = new_repo();
    $r->write_file('docs/modules/NoVersion/lib/Foo.pod', "=head1 Foo\n");
    $r->write_file('docs/modules/Bar-1.00/Bar.pod', "=head1 Bar\n");
    $r->commit_at('2025-06-01T12:00:00+0900', 'add unversioned dist dir');

    is [map { $_->{path} } @{ PJP::M::Repository->commit_events($c) }],
        ['docs/modules/Bar-1.00/Bar.pod'], '名前が導出できない path はイベントにならない';
};

subtest '日付の TZ は呼び出し元の環境に依存しない' => sub {
    # 負のオフセットのコミット。--date=iso のままだと壁時計が 00:00:00 のまま
    # 出て、JST の 16:00:00 と 16 時間ずれる。
    # 周囲の TZ を JST 以外にしても JST で観測されること = commit_events が
    # 日付の解釈を所有していること。ここが壊れると、手元での再導出を非 JST の
    # マシンで実行しただけで年境界のコミットが別の年に落ちる
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
    # 集計年と create_data.pl が導出する対象年の両方がずれる
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

subtest 'git log が途中で失敗したらビルドを止める' => sub {
    # 部分出力のまま EOF になっても、正常終了と区別して die しなければ
    # ならない (不完全なイベント列がそのまま生成物になるため)
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
};

{
    # assets_dir だけを返す最小のダブル
    package FakeContext;
    sub new { my ($class, $dir) = @_; bless { dir => $dir }, $class }
    sub assets_dir { $_[0]{dir} }
}

subtest 'assets_dir からの相対化' => sub {
    # 文字列置換で assets/ より前を削る方式は、祖先のディレクトリ名にも
    # assets/ があると切りすぎる。abs2rel なら祖先の名前に依存しない
    my $root = tempdir(CLEANUP => 1);
    my $assets = "$root/assets/work/assets";     # 祖先にも assets/ がある
    my $docs   = "$assets/translation/docs";
    File::Path::make_path("$docs/articles");
    open my $fh, '>', "$docs/articles/x.pod" or die $!;
    close $fh;

    my $c = FakeContext->new($assets);

    is PJP::M::Repository::assets_rel($c, "$assets/translation/docs"),
       File::Spec->catdir(qw/translation docs/), 'ディレクトリを受ける';
    is PJP::M::Repository::assets_rel($c, "$docs/articles/x.pod"),
       File::Spec->catfile(qw/translation docs articles x.pod/), 'ファイルを受ける';
    is PJP::M::Repository::assets_rel($c, $assets),
       File::Spec->curdir, 'assets root 自体は . になる';

    is PJP::M::Repository::repository_of($c, "$assets/translation/docs/modules"),
       'translation', '直下の checkout 名を返す';

    # 祖先の assets/ に引きずられていないこと (文字列置換だと 'work/assets/...' を
    # 切って別の repository 名になる)
    isnt PJP::M::Repository::repository_of($c, "$assets/translation/docs"), 'work',
        '祖先のディレクトリ名を拾わない';

    subtest 'assets_dir の外は止める' => sub {
        like dies { PJP::M::Repository::assets_rel($c, "$root/assets/work/outside") },
             qr/outside of assets_dir/, '1 段上';
        like dies { PJP::M::Repository::assets_rel($c, "$root/outside") },
             qr/outside of assets_dir/, '複数段上';

        # '..foo' は合法なディレクトリ名。/^\.\./ で見ると誤って弾く
        my $odd = "$assets/..foo";
        File::Path::make_path("$odd/inner");
        is PJP::M::Repository::assets_rel($c, "$odd/inner"),
           File::Spec->catdir('..foo', 'inner'), "'..foo' で始まる名前は通す";
        is PJP::M::Repository::repository_of($c, "$odd/inner"), '..foo',
           "'..foo' が repository 名になる";
    };
};

done_testing;
