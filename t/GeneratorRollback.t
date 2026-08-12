use v5.38;
use utf8;
use Test2::V0;

use Cwd ();
use File::Path qw/make_path/;
use File::Temp qw/tempdir/;
use Pod::Perldoc;
use PJP;
use PJP::M::BuiltinFunction;
use PJP::M::BuiltinVariable;

# PJP::M::Pod が c() 経由で assets_dir を引くので、コンテキストを立てておく
my $context = PJP->bootstrap;

# 生成が途中で失敗したとき、DB の commit と生成ファイルの差し替えより前に
# 止まることを固定する。順序が入れ替わると、失敗したビルドが部分的な内容を
# 確定させたまま完成してしまう (テーブルの中身も functions.txt も、
# 配信されるまで誰も気づかない)。
#
# DB は使わず、commit されたかどうかだけを記録するダブルを渡す。
# ここで見たいのは「die が commit より前にあること」であって、
# トランザクションそのものの動作ではない。
{
    package Test::Txn;
    sub new { bless { committed => 0 }, shift }
    sub commit { $_[0]{committed}++ }
    sub committed { $_[0]{committed} }
}
{
    package Test::Dbh;
    sub new { bless { txn => Test::Txn->new, rows => 0 }, shift }
    sub txn_scope { $_[0]{txn} }
    sub do     { }
    sub insert { $_[0]{rows}++ }
}
# perlfunc / perlop / perlvar の最小の pod を置いた assets を作る。
# 候補は C<...> から拾われるので、1 つだけ拾わせる
sub build_assets {
    my $assets = tempdir(CLEANUP => 1);
    my $dir    = "$assets/translation/docs/perl/5.42.0";
    make_path($dir);
    for my $name (qw/perlfunc perlop perlvar/) {
        open my $fh, '>', "$dir/$name.pod" or die $!;
        print $fh "=encoding utf-8\n\n=head1 NAME\n\n$name\n\nC<chomp>\n";
        close $fh;
    }
    return $assets;
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

# bootstrap 済みのコンテキストを、使い捨ての assets と DB のダブルに向ける
sub with_assets {
    my ($assets, $dbh) = @_;
    $context->config->{assets_dir} = $assets;
    no warnings 'redefine';
    *PJP::dbh_master = sub { $dbh };
    return $context;
}

sub slurp_file {
    open my $fh, '<', $_[0] or die $!;
    return do { local $/; <$fh> };
}

subtest 'BuiltinFunction は検索の異常で commit も functions.txt の差し替えもしない' => sub {
    my $dbh = Test::Dbh->new;
    my $c   = with_assets(build_assets(), $dbh);

    # 「見つからない」ではない失敗 (pod が読めない等) を起こす
    no warnings 'redefine';
    local *Pod::Perldoc::search_perlfunc = sub { die "Can't open perlfunc.pod: Permission denied\n" };
    local *Pod::Perldoc::search_perlop   = sub { die "Can't open perlop.pod: Permission denied\n" };

    in_tempdir sub {
        # 既にある一覧が壊れないことも見たいので、先に置いておく
        open my $fh, '>', 'functions.txt' or die $!;
        print $fh "existing\n";
        close $fh;

        like dies { PJP::M::BuiltinFunction->generate($c) },
            qr/cannot look up these builtins/, '失敗を集めて die する';
        is $dbh->{txn}->committed, 0, 'commit していない';
        is slurp_file('functions.txt'), "existing\n", '既存の functions.txt が変わらない';
    };
};

subtest 'BuiltinVariable は検索の異常で commit しない' => sub {
    my $dbh = Test::Dbh->new;
    my $c   = with_assets(build_assets(), $dbh);

    no warnings 'redefine';
    local *Pod::Perldoc::search_perlvar = sub { die "Can't open perlvar.pod: Permission denied\n" };

    like dies { PJP::M::BuiltinVariable->generate($c) },
        qr/cannot look up these builtins/, '失敗を集めて die する';
    is $dbh->{txn}->committed, 0, 'commit していない';
};

subtest '「見つからない」だけなら止まらない' => sub {
    # 候補には関数でも変数でもない文字列が混ざるのが正常。これで止まると
    # 実データでビルドが通らなくなる
    my $dbh = Test::Dbh->new;
    my $c   = with_assets(build_assets(), $dbh);

    no warnings 'redefine';
    local *Pod::Perldoc::search_perlvar = sub { die "No documentation for perl variable 'chomp' found\n" };

    ok lives { PJP::M::BuiltinVariable->generate($c) }, 'die しない';
    is $dbh->{txn}->committed, 1, 'commit する';
};

done_testing;
