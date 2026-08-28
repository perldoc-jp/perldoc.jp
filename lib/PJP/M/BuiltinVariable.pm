use strict;
use warnings;
use utf8;

package PJP::M::BuiltinVariable;
use PJP::M::Pod;
use Pod::Perldoc;
use Amon2::Declare;
use English ();
use PJP::Util qw/record_perldoc_failure/;

my @VARIABLES;
sub VARIABLES {
    my ($class, $name) = @_;
    if (not @VARIABLES) {
        foreach my $row (@{c->dbh->selectall_arrayref('SELECT name from var')}) {
	    push @VARIABLES, $row->[0];
	}
    }
    @VARIABLES;
}

my %VARIABLES;
sub exists {
    my ($class, $name) = @_;
    if (not %VARIABLES) {
	@VARIABLES{$class->VARIABLES} = ();
    }
    return exists $VARIABLES{$name};
}

sub retrieve {
    my ($class, $name) = @_;
    c->dbh->selectrow_array(q{SELECT version, html FROM var WHERE name=?}, {}, $name);
}

# perlvar.pod が宣言している encoding (無ければ undef)
sub _encoding_of {
    my ($path) = @_;
    open my $fh, '<', $path or die "Cannot open $path: $!";
    while (<$fh>) {
        return $1 if m{^=encoding\s+(.+)$};
    }
    return undef;
}

# 変数名の候補列。English の export 一覧と perlvar.pod の X<> から作る
sub _candidates {
    my ($path) = @_;

    my @candidate = map {
        # $_ は配列要素のエイリアスなので、コピーしてから置換する。
        # 直接いじると @English::COMPLETE_EXPORT から '*' が消え、
        # 同じプロセスで English を使う後続のコードが壊れる
        my $name = $_;
        $name =~ s{^\*}{} ? ('$' . $name, '%' . $name, '@' . $name) : $name;
    } @English::COMPLETE_EXPORT;

    open my $fh, '<', $path or die "Cannot open $path: $!";
    while (<$fh>) {
        push @candidate, m{X<< (.*?) >>}g;
        push @candidate, m{X<(.*?)>}g;
    }
    close $fh;

    my %uniq;
    @uniq{@candidate} = ();
    # keys の順は実行ごとに変わる。この列がそのまま var テーブルの
    # 挿入順になるので、並べ替えて生成物を決定的にする
    return sort keys %uniq;
}


sub generate {
    my ($class, $c) = @_;

    my $path_info = PJP::M::Pod->get_latest_file_path('perlvar');
    my ($path, $version) = @$path_info;

    my $encoding  = _encoding_of($path) || 'euc-jp';
    my @candidate = _candidates($path);

    my (@variables, @failures);
    my $txn = $c->dbh_master->txn_scope();
    $c->dbh_master->do(q{DELETE FROM var});
    for my $name (@candidate) {
        my @dynamic_pod;
	my $perldoc = Pod::Perldoc->new(opt_v => $name);
	eval {
	    $perldoc->search_perlvar([$path], \@dynamic_pod);
	    1;
	} or record_perldoc_failure(\@failures, $name, $@);
	next if not @dynamic_pod;

	push @variables, $name;
        my $pod = join("", "=encoding $encoding\n\n=over 4\n\n", @dynamic_pod, "=back\n");
        $pod =~ s!L</([a-z]+)>!L<$1|https://perldoc.jp/variable/$1>!g;
        my $html = PJP::M::Pod->pod2html(\$pod);
	$c->dbh_master->insert(
			       var => {
				       name    => $name,
				       version => $version,
				       html    => $html,
				      },
			      );
    }

    # commit より前に判定する。後に置くと、失敗したビルドが部分的な
    # var テーブルを確定させてしまう
    die "cannot look up these builtins:\n" . join('', map { "  $_\n" } @failures)
        if @failures;

    $txn->commit();
}

1;
