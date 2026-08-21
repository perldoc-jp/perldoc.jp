use v5.38;
use utf8;
use Test2::V0;

use Cwd ();
use File::Basename ();
use File::Path ();
use File::Temp qw/tempdir/;

# script/translation.sh は translation の取得と、取得したものが生成の入力として
# 完全かの検査を持つ。branch を動かす状態機械かつ入力完全性の門番なので、
# 一度きりの手動確認では足りない。
#
# fixture は一時 bare リポジトリを origin にしてネットワーク無しで回す。
# 取得元は TRANSLATION_ORIGIN_URL で差し替える (信頼できる呼び出し元のための
# test seam。Dockerfile と workflows はこれを設定しない)。
my $SCRIPT = Cwd::abs_path('script/translation.sh');
ok -x $SCRIPT, 'script/translation.sh は実行可能';

# 外部の gitconfig から切り離す。fixture の commit に user.email が要るので
# 環境で与える (Dockerfile の test ステージには global gitconfig が無く、
# 手元の設定に頼るとローカルだけ緑で CI で落ちる)。
# core.autocrlf 等がテスト結果を揺らすのも防ぐ
my %GIT_ENV = (
    GIT_CONFIG_GLOBAL => '/dev/null',
    GIT_CONFIG_SYSTEM => '/dev/null',
    GIT_AUTHOR_NAME    => 'test',
    GIT_AUTHOR_EMAIL   => 'test@example.com',
    GIT_COMMITTER_NAME => 'test',
    GIT_COMMITTER_EMAIL=> 'test@example.com',
    GIT_AUTHOR_DATE    => '2026-01-01T00:00:00+0900',
    GIT_COMMITTER_DATE => '2026-01-01T00:00:00+0900',
);

sub run {
    my (%opt) = @_;
    my @cmd = @{ $opt{cmd} };
    my %env = (%GIT_ENV, %{ $opt{env} // {} });
    my $out = File::Temp->new;
    my $err = File::Temp->new;
    my $pid = fork // die "fork: $!";
    if (!$pid) {
        $ENV{$_} = $env{$_} for keys %env;
        delete $ENV{$_} for grep { !defined $env{$_} } keys %env;
        open STDOUT, '>&', $out or die $!;
        open STDERR, '>&', $err or die $!;
        chdir $opt{cwd} or die $! if $opt{cwd};
        exec @cmd or die "exec @cmd: $!";
    }
    waitpid $pid, 0;
    my $status = $? >> 8;
    return {
        status => $status,
        out    => do { open my $fh, '<', $out->filename or die $!; local $/; <$fh> } // '',
        err    => do { open my $fh, '<', $err->filename or die $!; local $/; <$fh> } // '',
    };
}

sub git { my $dir = shift; return run(cmd => ['git', '-C', $dir, @_]) }

sub git_ok {
    my $dir = shift;
    my $r = git($dir, @_);
    die "git @_ failed in $dir: $r->{err}" if $r->{status} != 0;
    my $out = $r->{out};
    chomp $out;
    return $out;
}

# origin と、docs を持つ 3 世代の履歴を作る。
# 1 世代目には docs が無い (translation の root commit と同じ形)
sub build_origin {
    my (%opt) = @_;
    my $root   = tempdir(CLEANUP => 1);
    my $origin = "$root/origin.git";
    my $seed   = "$root/seed";

    run(cmd => ['git', 'init', '--quiet', '--bare', '--initial-branch=master', $origin]);
    run(cmd => ['git', 'init', '--quiet', '--initial-branch=master', $seed]);
    $opt{allow_filter} and git_ok($origin, 'config', 'uploadpack.allowFilter', 'true');

    # 1) docs の無い commit
    _write("$seed/README.md", "readme\n");
    git_ok($seed, 'add', '-A');
    git_ok($seed, 'commit', '--quiet', '-m', 'root');
    my $rootrev = git_ok($seed, 'rev-parse', 'HEAD');

    # 2) docs を足す
    _write("$seed/docs/modules/Foo-1.00/Foo.pod", "=head1 NAME\n\nFoo\n");
    git_ok($seed, 'add', '-A');
    git_ok($seed, 'commit', '--quiet', '-m', 'add docs');
    my $mid = git_ok($seed, 'rev-parse', 'HEAD');

    # 3) 同じ path の blob を更新する (partial clone に欠落 object を残すため)
    _write("$seed/docs/modules/Foo-1.00/Foo.pod", "=head1 NAME\n\nFoo v2\n");
    git_ok($seed, 'add', '-A');
    git_ok($seed, 'commit', '--quiet', '-m', 'update docs');
    my $tip = git_ok($seed, 'rev-parse', 'HEAD');

    # master から到達できない branch (fresh clone でも拒否されること用)
    git_ok($seed, 'checkout', '--quiet', '-b', 'side');
    _write("$seed/docs/side.pod", "=head1 NAME\n\nSide\n");
    git_ok($seed, 'add', '-A');
    git_ok($seed, 'commit', '--quiet', '-m', 'side');
    my $side = git_ok($seed, 'rev-parse', 'HEAD');
    git_ok($seed, 'checkout', '--quiet', 'master');

    git_ok($seed, 'tag', '-a', 'v1', '-m', 'tag');
    my $tagobj = git_ok($seed, 'rev-parse', 'v1');
    my $blob   = git_ok($seed, 'rev-parse', 'HEAD:docs/modules/Foo-1.00/Foo.pod');
    my $tree   = git_ok($seed, 'rev-parse', 'HEAD^{tree}');

    git_ok($seed, 'remote', 'add', 'origin', $origin);
    git_ok($seed, 'push', '--quiet', 'origin', 'master', 'side');
    git_ok($seed, 'push', '--quiet', 'origin', '--tags');

    return {
        root => $root, origin => $origin, seed => $seed,
        rootrev => $rootrev, mid => $mid, tip => $tip, side => $side,
        tagobj => $tagobj, blob => $blob, tree => $tree,
    };
}

sub _write {
    my ($path, $body) = @_;
    File::Path::make_path(File::Basename::dirname($path));
    open my $fh, '>:raw', $path or die "$path: $!";
    print {$fh} $body;
    close $fh;
}

sub fetch {
    my ($fx, $dir, $ref, %env) = @_;
    return run(
        cmd => [$SCRIPT, 'fetch', $dir, (defined $ref ? ($ref) : ())],
        env => { TRANSLATION_ORIGIN_URL => $fx->{origin}, %env },
    );
}

# 通常の (非 partial・非 shallow) clone を作る
sub clone_plain {
    my ($fx, $dir, @args) = @_;
    my $r = run(cmd => ['git', 'clone', '--quiet', @args, $fx->{origin}, $dir]);
    die "clone failed: $r->{err}" if $r->{status} != 0;
    return $dir;
}

subtest 'head は master の SHA を 1 行返す' => sub {
    my $fx = build_origin();
    my $r = run(cmd => [$SCRIPT, 'head'],
                env => { TRANSLATION_ORIGIN_URL => $fx->{origin} });
    is $r->{status}, 0, '成功する';
    is $r->{out}, "$fx->{tip}\n", 'master HEAD の SHA 1 行';
};

subtest 'リポジトリ局所の環境変数に引きずられない' => sub {
    my $fx    = build_origin();
    my $decoy = build_origin();
    my $dir   = "$fx->{root}/work";
    clone_plain($fx, $dir);
    my $decoy_clone = "$decoy->{root}/decoy";
    clone_plain($decoy, $decoy_clone);

    my $r = fetch($fx, $dir, undef,
        GIT_DIR        => "$decoy_clone/.git",
        GIT_WORK_TREE  => $decoy_clone,
        GIT_INDEX_FILE => "$decoy_clone/.git/index",
    );
    is $r->{status}, 0, "decoy の GIT_DIR があっても成功する: $r->{err}";
    is git_ok($dir, 'rev-parse', 'HEAD'), $fx->{tip}, '引数で指定した方が動く';
    is git_ok($decoy_clone, 'rev-parse', 'HEAD'), $decoy->{tip}, 'decoy は動かない';
};

subtest '状態遷移' => sub {
    subtest 'ディレクトリが無ければ clone して master に留まる' => sub {
        my $fx  = build_origin();
        my $dir = "$fx->{root}/fresh";
        my $r = fetch($fx, $dir);
        is $r->{status}, 0, "成功する: $r->{err}";
        is git_ok($dir, 'rev-parse', 'HEAD'), $fx->{tip}, 'master HEAD にいる';
        is git_ok($dir, 'symbolic-ref', '--short', 'HEAD'), 'master',
            'ref 既定では master branch のまま (detach しない)';

        # 直後の再実行は HEAD == target の冪等経路。fast-forward は通らない
        my $again = fetch($fx, $dir);
        is $again->{status}, 0, '2 回目も成功する (冪等)';
        is git_ok($dir, 'symbolic-ref', '--short', 'HEAD'), 'master', 'master のまま';
    };

    subtest 'master が進んでいれば fast-forward する' => sub {
        my $fx  = build_origin();
        my $dir = "$fx->{root}/ff";
        clone_plain($fx, $dir);
        git_ok($dir, 'reset', '--hard', '--quiet', $fx->{mid});

        my $r = fetch($fx, $dir);
        is $r->{status}, 0, "成功する: $r->{err}";
        is git_ok($dir, 'rev-parse', 'HEAD'), $fx->{tip}, 'tip まで進む';
        is git_ok($dir, 'symbolic-ref', '--short', 'HEAD'), 'master', 'master のまま';
    };

    subtest 'fresh clone は完全 OID で detach する' => sub {
        my $fx  = build_origin();
        my $dir = "$fx->{root}/pinned";
        my $r = fetch($fx, $dir, $fx->{mid});
        is $r->{status}, 0, "成功する: $r->{err}";
        is git_ok($dir, 'rev-parse', 'HEAD'), $fx->{mid}, '指定した OID にいる';
        my $sym = git($dir, 'symbolic-ref', '--quiet', 'HEAD');
        isnt $sym->{status}, 0, 'detached HEAD になる';
    };

    subtest 'master 以外・ahead・分岐は止める' => sub {
        my $fx = build_origin();

        my $ahead = "$fx->{root}/ahead";
        clone_plain($fx, $ahead);
        _write("$ahead/extra.txt", "x\n");
        git_ok($ahead, 'add', '-A');
        git_ok($ahead, 'commit', '--quiet', '-m', 'local');
        my $r = fetch($fx, $ahead);
        isnt $r->{status}, 0, 'ahead は止める';
        like $r->{err}, qr/clean master that can fast-forward/, '理由が出る';

        my $branch = "$fx->{root}/branch";
        clone_plain($fx, $branch);
        git_ok($branch, 'reset', '--hard', '--quiet', $fx->{mid});
        git_ok($branch, 'checkout', '--quiet', '-b', 'work');
        $r = fetch($fx, $branch);
        isnt $r->{status}, 0, 'master 以外の branch は止める';

        my $detached = "$fx->{root}/detached";
        clone_plain($fx, $detached);
        git_ok($detached, 'checkout', '--quiet', '--detach', $fx->{mid});
        $r = fetch($fx, $detached);
        isnt $r->{status}, 0, '既存 checkout の detached は止める';
    };
};

subtest '到達可能性は fresh clone にも効く' => sub {
    my $fx = build_origin();

    my $fresh = "$fx->{root}/fresh-side";
    my $r = fetch($fx, $fresh, $fx->{side});
    isnt $r->{status}, 0, 'master に無い branch の OID は fresh clone でも拒否';
    like $r->{err}, qr/not reachable from master/, '理由が出る';

    my $existing = "$fx->{root}/existing-side";
    clone_plain($fx, $existing);
    $r = fetch($fx, $existing, $fx->{side});
    isnt $r->{status}, 0, '既存ディレクトリでも同じ判定';
};

subtest 'ref の文法と object の型' => sub {
    my $fx  = build_origin();
    my $dir = "$fx->{root}/refsyntax";
    clone_plain($fx, $dir);

    for my $bad ('-x', 'refs/heads/master:refs/heads/x', 'refs/heads/*', 'has space',
                 'MASTER', substr($fx->{tip}, 0, 8)) {
        my $r = fetch($fx, $dir, $bad);
        isnt $r->{status}, 0, "拒否する: $bad";
        like $r->{err}, qr/ref must be/, "文法違反として弾く: $bad";
    }

    for my $pair ([tagobj => 'tag'], [blob => 'blob'], [tree => 'tree']) {
        my ($key, $type) = @$pair;
        my $r = fetch($fx, $dir, $fx->{$key});
        isnt $r->{status}, 0, "$type の OID は拒否する";
        like $r->{err}, qr/is a $type, not a commit/, "型で弾く: $type";
    }
};

subtest 'SKIP_ASSETS_UPDATE' => sub {
    my $fx = build_origin();

    subtest '既存ディレクトリは何も検査せず何も触らない' => sub {
        my $dir = "$fx->{root}/skip";
        clone_plain($fx, $dir);
        git_ok($dir, 'reset', '--hard', '--quiet', $fx->{mid});
        # 非 Git でも dirty でも origin 不一致でも通ることを、dirty で代表させる
        _write("$dir/dirty.txt", "x\n");
        git_ok($dir, 'remote', 'set-url', 'origin', 'https://example.com/other.git');

        my $r = fetch($fx, $dir, undef, SKIP_ASSETS_UPDATE => 1);
        is $r->{status}, 0, "成功する: $r->{err}";
        is git_ok($dir, 'rev-parse', 'HEAD'), $fx->{mid}, 'HEAD が動かない';
    };

    subtest 'ディレクトリが無ければ通常経路を通り ref も効く' => sub {
        my $dir = "$fx->{root}/skip-missing";
        my $r = fetch($fx, $dir, $fx->{mid}, SKIP_ASSETS_UPDATE => 1);
        is $r->{status}, 0, "成功する: $r->{err}";
        is git_ok($dir, 'rev-parse', 'HEAD'), $fx->{mid}, '指定した OID にいる';
    };

    subtest '値ごとの挙動' => sub {
        for my $value ('', '0') {
            my $dir = "$fx->{root}/skipval-" . ($value eq '' ? 'empty' : $value);
            my $r = fetch($fx, $dir, undef, SKIP_ASSETS_UPDATE => $value);
            is $r->{status}, 0, "'$value' は通常更新: $r->{err}";
        }
        for my $value (qw/true yes 2/) {
            my $dir = "$fx->{root}/skipbad-$value";
            my $r = fetch($fx, $dir, undef, SKIP_ASSETS_UPDATE => $value);
            isnt $r->{status}, 0, "'$value' は止める";
            like $r->{err}, qr/SKIP_ASSETS_UPDATE must be/, '理由が出る';
            ok !-d $dir, 'リポジトリを作る前に止まる';
        }
    };
};

subtest '構造の異常を拒否する' => sub {
    my $fx = build_origin();

    subtest 'origin 不一致' => sub {
        my $dir = "$fx->{root}/badorigin";
        clone_plain($fx, $dir);
        git_ok($dir, 'remote', 'set-url', 'origin', 'https://example.com/other.git');
        my $r = fetch($fx, $dir);
        isnt $r->{status}, 0, '止める';
        like $r->{err}, qr/origin is not the expected URL/, '理由が出る';
    };

    subtest '非 Git ディレクトリ' => sub {
        my $dir = "$fx->{root}/notgit";
        File::Path::make_path($dir);
        my $r = fetch($fx, $dir);
        isnt $r->{status}, 0, '止める';
        like $r->{err}, qr/not a git repository/, '理由が出る';
    };

    subtest 'dirty' => sub {
        for my $case (['tracked', sub { _write("$_[0]/README.md", "changed\n") }],
                      ['untracked', sub { _write("$_[0]/new.txt", "x\n") }]) {
            my ($label, $make) = @$case;
            my $dir = "$fx->{root}/dirty-$label";
            clone_plain($fx, $dir);
            $make->($dir);
            my $r = fetch($fx, $dir);
            isnt $r->{status}, 0, "$label は止める";
            like $r->{err}, qr/has local changes/, "理由が出る: $label";
        }
    };

    subtest 'sparse checkout' => sub {
        my $dir = "$fx->{root}/sparse";
        clone_plain($fx, $dir);
        git_ok($dir, 'config', 'core.sparseCheckout', 'true');
        my $r = fetch($fx, $dir);
        isnt $r->{status}, 0, '止める';
        like $r->{err}, qr/sparse checkout/, '理由が出る';
    };

    subtest 'index の flag' => sub {
        # assume-unchanged は小文字 h、skip-worktree は大文字 S。
        # 「小文字を拒否」では S を見逃す fail-open になる
        for my $case (['assume-unchanged', '--assume-unchanged'],
                      ['skip-worktree',    '--skip-worktree']) {
            my ($label, $flag) = @$case;
            my $dir = "$fx->{root}/flag-$label";
            clone_plain($fx, $dir);
            git_ok($dir, 'update-index', $flag, 'docs/modules/Foo-1.00/Foo.pod');
            my $r = fetch($fx, $dir);
            isnt $r->{status}, 0, "$label は止める";
            like $r->{err}, qr/not plain tracked files/, "理由が出る: $label";
        }
    };

    subtest 'replace ref' => sub {
        my $dir = "$fx->{root}/replace";
        clone_plain($fx, $dir);
        git_ok($dir, 'replace', $fx->{tip}, $fx->{mid});
        my $r = fetch($fx, $dir);
        isnt $r->{status}, 0, '止める';
        like $r->{err}, qr/replace refs/, '理由が出る';
    };

    subtest 'grafts' => sub {
        my $dir = "$fx->{root}/grafts";
        clone_plain($fx, $dir);
        _write("$dir/.git/info/grafts", "$fx->{tip}\n");
        my $r = fetch($fx, $dir);
        isnt $r->{status}, 0, '止める';
        like $r->{err}, qr/grafts file/, '理由が出る';
    };
};

subtest '入力完全性' => sub {
    my $fx = build_origin();

    subtest 'docs がまだ無い祖先からでも更新できる' => sub {
        my $dir = "$fx->{root}/from-rootless";
        clone_plain($fx, $dir);
        git_ok($dir, 'reset', '--hard', '--quiet', $fx->{rootrev});
        ok !-d "$dir/docs", '出発点には docs が無い';
        my $r = fetch($fx, $dir);
        is $r->{status}, 0, "成功する: $r->{err}";
        is git_ok($dir, 'rev-parse', 'HEAD'), $fx->{tip}, 'tip まで進む';
    };

    subtest 'target 自体に docs が無ければ移動後に失敗する' => sub {
        my $dir = "$fx->{root}/target-rootless";
        my $r = fetch($fx, $dir, $fx->{rootrev});
        isnt $r->{status}, 0, '止める';
        like $r->{err}, qr/no docs directory/, '理由が出る';
    };

    subtest 'docs の ignored なファイル' => sub {
        my $dir = "$fx->{root}/ignored";
        clone_plain($fx, $dir);
        _write("$dir/.git/info/exclude", "*.tmp\n");
        _write("$dir/docs/stray.tmp", "x\n");
        my $r = fetch($fx, $dir);
        isnt $r->{status}, 0, '止める';
        like $r->{err}, qr{docs is not clean}, '理由が出る';
    };

    subtest 'symlink と gitlink' => sub {
        # 拒否は index の mode (120000 / 160000) で行うので、file 宛ての
        # symlink 1 本で足りる (directory 宛ても同じ経路に落ちる)
        my $sfx = build_origin();
        symlink 'Foo.pod', "$sfx->{seed}/docs/modules/Foo-1.00/link.pod" or die $!;
        git_ok($sfx->{seed}, 'add', '-A');
        git_ok($sfx->{seed}, 'commit', '--quiet', '-m', 'symlink');
        git_ok($sfx->{seed}, 'push', '--quiet', 'origin', 'master');

        my $dir = "$sfx->{root}/symlink";
        my $r = fetch($sfx, $dir);
        isnt $r->{status}, 0, 'symlink は止める';
        like $r->{err}, qr/not plain tracked files/, '理由が出る';
    };

    subtest '作業ツリーのバイト列が index と食い違う' => sub {
        my $dir = "$fx->{root}/autocrlf";
        clone_plain($fx, $dir);
        git_ok($dir, 'config', 'core.autocrlf', 'true');
        # 変換を実際に適用させる
        unlink "$dir/docs/modules/Foo-1.00/Foo.pod";
        git_ok($dir, 'checkout', '--', 'docs');
        _write("$dir/docs/modules/Foo-1.00/Foo.pod", "=head1 NAME\r\n\r\nFoo v2\r\n");
        my $r = fetch($fx, $dir);
        isnt $r->{status}, 0, '止める';
    };

    subtest 'バイト列を変えない属性は通す' => sub {
        my $afx = build_origin();
        _write("$afx->{seed}/.gitattributes", "*.pod diff=pod\n");
        git_ok($afx->{seed}, 'add', '-A');
        git_ok($afx->{seed}, 'commit', '--quiet', '-m', 'attrs');
        git_ok($afx->{seed}, 'push', '--quiet', 'origin', 'master');

        my $dir = "$afx->{root}/benign-attr";
        my $r = fetch($afx, $dir);
        is $r->{status}, 0, "diff 属性は拒否しない: $r->{err}";
    };
};

subtest 'shallow / partial clone' => sub {
    # ローカルパスからの clone では --depth も --filter も無視される
    # (--filter は警告つきで config だけ書かれ object は全部揃う)。
    # file:// と bare 側の uploadpack.allowFilter=true が要る
    my $fx = build_origin(allow_filter => 1);
    my $url = 'file://' . $fx->{origin};

    # 名前つき sub はコンパイル時に作られて $url を閉じ込められないので無名 sub
    my $clone_url = sub {
        my ($dir, @args) = @_;
        my $r = run(cmd => ['git', 'clone', '--quiet', @args, $url, $dir]);
        die "clone failed: $r->{err}" if $r->{status} != 0;
        return $dir;
    };

    my $fetch_url = sub {
        my ($dir, $ref) = @_;
        return run(cmd => [$SCRIPT, 'fetch', $dir, (defined $ref ? ($ref) : ())],
                   env => { TRANSLATION_ORIGIN_URL => $url });
    };

    subtest 'shallow は拒否する' => sub {
        my $dir = $clone_url->("$fx->{root}/shallow", '--depth=1');
        is git_ok($dir, 'rev-parse', '--is-shallow-repository'), 'true',
            '前提: 本当に shallow';
        my $r = $fetch_url->($dir);
        isnt $r->{status}, 0, '止める';
        like $r->{err}, qr/shallow clone/, '理由が出る';
    };

    subtest 'blob:none は通す' => sub {
        my $dir = $clone_url->("$fx->{root}/blobnone", '--filter=blob:none');
        # 前提: 実際に欠落 object がある。--objects を付けないと commit しか
        # 歩かないので、正しい blob:none clone でも 0 件になる
        my $missing = run(cmd => ['git', '-C', $dir, 'rev-list', '--objects',
                                  '--no-object-names', '--missing=print', 'HEAD'],
                          env => { GIT_NO_LAZY_FETCH => 1 });
        like $missing->{out}, qr/^\?/m, '前提: 欠落 object がある';

        my $r = $fetch_url->($dir);
        is $r->{status}, 0, "通す: $r->{err}";
    };

    subtest 'tree:0 は拒否する' => sub {
        my $dir = $clone_url->("$fx->{root}/tree0", '--filter=tree:0');
        my $r = $fetch_url->($dir);
        isnt $r->{status}, 0, '止める';
        like $r->{err}, qr/walk its history offline/, '理由が出る';
    };

    subtest 'config を blob:none に偽装した tree:0 も拒否する' => sub {
        my $dir = $clone_url->("$fx->{root}/forged", '--filter=tree:0');
        git_ok($dir, 'config', 'remote.origin.partialclonefilter', 'blob:none');
        my $r = $fetch_url->($dir);
        isnt $r->{status}, 0, 'config 照合では通り抜けるが、走査の実行検査で止まる';
        like $r->{err}, qr/walk its history offline/, '理由が出る';
    };
};

subtest 'fetch できないときは止める' => sub {
    my $fx  = build_origin();
    my $dir = "$fx->{root}/gone";
    clone_plain($fx, $dir);
    File::Path::remove_tree($fx->{origin});
    my $r = fetch($fx, $dir);
    isnt $r->{status}, 0, '止める';
};

done_testing;
