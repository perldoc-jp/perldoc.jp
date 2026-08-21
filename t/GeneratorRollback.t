use v5.38;
use utf8;
use Test2::V0;

use Cwd ();
use File::Path qw/make_path/;
use File::Temp qw/tempdir/;
use Encode ();
use Pod::Perldoc;
use PJP;
use PJP::DBI;
use PJP::M::Pod;
use PJP::M::PodFile;
use PJP::M::BuiltinFunction;
use PJP::M::BuiltinVariable;

# 生成が途中で失敗したとき、DB の commit と生成ファイルの差し替えより前に
# 止まることを固定する。順序が入れ替わったり、書き込みがトランザクションの
# 外へ出たりすると、失敗したビルドが部分的な内容を確定させたまま完成する
# (テーブルの中身も functions.txt も、配信されるまで誰も気づかない)。
#
# DB はダブルではなく in-memory の SQLite を使う。ダブルだと
# 「txn_scope を外す」「DELETE がトランザクションの外へ出る」といった
# 変更を素通しさせてしまう。

my $context = PJP->bootstrap;

# 本物のスキーマの in-memory DB に差し替える。生成前に 1 行ずつ入れておき、
# 失敗した生成がそれを消していないことを見る
sub with_fresh_db {
    my ($assets, $cb) = @_;

    my $dbh = PJP::DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {});
    open my $schema, '<', 'sql/sqlite.sql' or die $!;
    my $sql = do { local $/; <$schema> };
    close $schema;
    $dbh->do($_) for grep { /\S/ } split /;/, $sql;

    $dbh->insert(func => { name => 'existing_func', version => '5.42.0', html => '<p>keep</p>' });
    $dbh->insert(var  => { name => '$existing',    version => '5.42.0', html => '<p>keep</p>' });
    $dbh->insert(pod  => {
        path => 'modules/Keep-1.00/Keep.pod', package => 'Keep',
        distvname => 'Keep-1.00', repository => 'translation', html => '<p>keep</p>',
    });

    local $context->{db_master} = $dbh;
    local $context->{db}        = $dbh;
    local $context->config->{assets_dir} = $assets;
    $cb->($dbh);
}

sub rows_of {
    my ($dbh, $table) = @_;
    return $dbh->selectall_arrayref("SELECT name FROM $table ORDER BY name") if $table ne 'pod';
    return $dbh->selectall_arrayref('SELECT path FROM pod ORDER BY path');
}

# perlfunc / perlop / perlvar の最小の pod を置いた assets を作る。
# 候補は C<...> から拾われるので、2 つ拾わせて「1 件目は成功、2 件目で失敗」を作る
sub build_assets {
    my $assets = tempdir(CLEANUP => 1);
    my $dir    = "$assets/translation/docs/perl/5.42.0";
    make_path($dir);
    for my $name (qw/perlfunc perlop perlvar/) {
        open my $fh, '>', "$dir/$name.pod" or die $!;
        print $fh "=encoding utf-8\n\n=head1 NAME\n\n$name\n\nC<aaa> C<bbb>\n";
        close $fh;
    }
    return $assets;
}

# 翻訳文書を 2 つ置いた assets (PodFile->generate 用)
sub build_docs_assets {
    my $assets = tempdir(CLEANUP => 1);
    my $dir    = "$assets/translation/docs/modules";
    make_path("$dir/Aaa-1.00");
    make_path("$dir/Bbb-1.00");
    for my $name (qw/Aaa Bbb/) {
        open my $fh, '>', "$dir/$name-1.00/$name.pod" or die $!;
        print $fh "=encoding utf-8\n\n=head1 NAME\n\n$name - test\n";
        close $fh;
    }
    return $assets;
}

# 1 件目は本来の処理を通し、2 件目以降で異常な失敗を起こす
sub failing_after_first {
    my ($original, $error) = @_;
    my $seen = 0;
    return sub {
        die $error->($_[0]) if $seen++;
        return $original->(@_);
    };
}

sub in_tempdir {
    my ($cb) = @_;
    my $orig = Cwd::getcwd();
    my $dir  = tempdir(CLEANUP => 1);
    chdir $dir or die $!;
    my $guard = Guard->new(sub { chdir $orig or die $! });
    $cb->($dir);
}
{
    package Guard;
    sub new { my ($class, $cb) = @_; bless { cb => $cb }, $class }
    sub DESTROY { $_[0]->{cb}->() }
}

sub slurp_file {
    open my $fh, '<', $_[0] or die $!;
    return do { local $/; <$fh> };
}

subtest 'BuiltinFunction は失敗したら func テーブルも functions.txt も変えない' => sub {
    with_fresh_db build_assets(), sub {
        my ($dbh) = @_;
        my $before = rows_of($dbh, 'func');

        # 1 件目は通し、2 件目で「見つからない」ではない失敗を起こす
        my $original = \&Pod::Perldoc::search_perlfunc;
        no warnings 'redefine';
        local *Pod::Perldoc::search_perlfunc = failing_after_first(
            $original, sub { "Can't open perlfunc.pod: Permission denied\n" });

        in_tempdir sub {
            open my $fh, '>', 'functions.txt' or die $!;
            print $fh "existing\n";
            close $fh;

            my $error = dies { PJP::M::BuiltinFunction->generate($context) };
            like $error, qr/cannot look up these builtins/, '失敗を集めて die する';
            like $error, qr/bbb/, '失敗した候補の名前が残る';

            is rows_of($dbh, 'func'), $before, 'func テーブルが元のまま (DELETE ごと巻き戻る)';
            is slurp_file('functions.txt'), "existing\n", '既存の functions.txt が変わらない';
        };
    };
};

subtest 'BuiltinFunction は複数の失敗をまとめて報告する' => sub {
    with_fresh_db build_assets(), sub {
        my ($dbh) = @_;

        no warnings 'redefine';
        local *Pod::Perldoc::search_perlfunc = sub { die "Can't open perlfunc.pod: $_[0]->{opt_f}\n" };
        local *Pod::Perldoc::search_perlop   = sub { die "Can't open perlop.pod\n" };

        in_tempdir sub {
            my $error = dies { PJP::M::BuiltinFunction->generate($context) };
            like $error, qr/aaa/, '1 つ目の失敗が残る';
            like $error, qr/bbb/, '2 つ目の失敗も残る (最初の 1 件で止めない)';
        };
    };
};

subtest 'BuiltinVariable は失敗したら var テーブルを変えない' => sub {
    with_fresh_db build_assets(), sub {
        my ($dbh) = @_;
        my $before = rows_of($dbh, 'var');

        my $original = \&Pod::Perldoc::search_perlvar;
        no warnings 'redefine';
        local *Pod::Perldoc::search_perlvar = failing_after_first(
            $original, sub { "Can't open perlvar.pod: Permission denied\n" });

        my $error = dies { PJP::M::BuiltinVariable->generate($context) };
        like $error, qr/cannot look up these builtins/, '失敗を集めて die する';
        is rows_of($dbh, 'var'), $before, 'var テーブルが元のまま';
    };
};

subtest 'PodFile は失敗したら pod テーブルを変えない' => sub {
    with_fresh_db build_docs_assets(), sub {
        my ($dbh) = @_;
        my $before = rows_of($dbh, 'pod');

        # generate は組み込み関数の一覧が空だと先に die するので埋めておく
        local @PJP::M::BuiltinFunction::REGEXP = ('chomp');

        my $original = \&PJP::M::Pod::pod2html;
        no warnings 'redefine';
        local *PJP::M::Pod::pod2html = failing_after_first(
            $original, sub { "cannot convert this pod\n" });

        my $error = dies { PJP::M::PodFile->generate($context) };
        like $error, qr/cannot generate these documents/, '失敗を集めて die する';
        is rows_of($dbh, 'pod'), $before, 'pod テーブルが元のまま (DELETE ごと巻き戻る)';
    };
};

subtest '「見つからない」だけなら止まらない' => sub {
    # 候補には関数でも変数でもない文字列が混ざるのが正常。これで止まると
    # 実データでビルドが通らなくなる
    with_fresh_db build_assets(), sub {
        my ($dbh) = @_;

        no warnings 'redefine';
        local *Pod::Perldoc::search_perlvar = sub { die "No documentation for perl variable 'x' found\n" };

        ok lives { PJP::M::BuiltinVariable->generate($context) }, 'die しない';
        # 候補が 1 つも見つからなければ、DELETE だけが確定して空になる
        is rows_of($dbh, 'var'), [], 'commit された結果が反映される';
    };
};

subtest 'PodFile の repository は assets_dir 直下の checkout 名になる' => sub {
    # assets_dir の祖先にも 'assets' component がある場合。文字列置換で
    # assets/ より前を削る方式だと、削りすぎたり (祖先が assets/) 一文字も
    # 削れなかったり (assets component が無い tempdir) して、repository 欄に
    # 一時ディレクトリの絶対 path がそのまま入っていた
    my $root   = tempdir(CLEANUP => 1);
    my $assets = "$root/assets/work/assets";
    my $dir    = "$assets/translation/docs/modules/Ccc-1.00";
    make_path($dir);
    open my $fh, '>', "$dir/Ccc.pod" or die $!;
    print $fh "=encoding utf-8\n\n=head1 NAME\n\nCcc - test\n";
    close $fh;

    with_fresh_db $assets, sub {
        my ($dbh) = @_;
        local @PJP::M::BuiltinFunction::REGEXP = ('chomp');
        PJP::M::PodFile->generate($context);

        my $rows = $dbh->selectall_arrayref(
            q{SELECT DISTINCT repository FROM pod WHERE path LIKE 'modules/Ccc%'});
        is $rows, [['translation']], 'repository は translation';
    };
};

subtest 'pod テーブルの path は境界で decode される' => sub {
    my $root   = tempdir(CLEANUP => 1);
    my $assets = "$root/assets";
    my $dir    = "$assets/translation/docs/modules/Acme-日本語-1.00";
    make_path(Encode::encode_utf8($dir));
    open my $fh, '>:raw', Encode::encode_utf8("$dir/日本語.pod") or die $!;
    print $fh "=encoding utf-8\n\n=head1 NAME\n\nAcme::Sample - test\n";
    close $fh;

    with_fresh_db $assets, sub {
        my ($dbh) = @_;
        local @PJP::M::BuiltinFunction::REGEXP = ('chomp');
        PJP::M::PodFile->generate($context);

        my ($path) = $dbh->selectrow_array(
            q{SELECT path FROM pod WHERE path LIKE 'modules/Acme%'});
        ok utf8::is_utf8($path), 'path は decode 済みの文字列';
        is $path, 'modules/Acme-日本語-1.00/日本語.pod', '非 ASCII のまま復元できる';
    };
};

subtest '不正な UTF-8 のファイル名は止める' => sub {
    my $root   = tempdir(CLEANUP => 1);
    my $assets = "$root/assets";
    my $dir    = "$assets/translation/docs/modules/Bad-1.00";
    make_path($dir);
    # \xFF は単独では正しい UTF-8 にならない
    my $bad = "$dir/\xFF.pod";
    my $ok = eval { open my $fh, '>:raw', $bad or die $!; print $fh "=head1 NAME\n\nBad\n"; close $fh; 1 };
    skip_all 'cannot create a file with invalid UTF-8 name on this filesystem' unless $ok;

    with_fresh_db $assets, sub {
        local @PJP::M::BuiltinFunction::REGEXP = ('chomp');
        like dies { PJP::M::PodFile->generate($context) },
             qr/cannot generate these documents/,
             '置換文字に倒さず失敗として集める';
    };
};

done_testing;
