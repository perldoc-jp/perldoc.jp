use strict;
use warnings;
use utf8;

package PJP::M::BuiltinVariable;
use PJP::M::Pod;
use Pod::Perldoc;
use Amon2::Declare;
use English ();

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

sub generate {
    my ($class, $c) = @_;

    my $path_info = PJP::M::Pod->get_latest_file_path('perlvar');
    my ($path, $version) = @$path_info;

    my @candidate = do
        {
            my @_candidate = map {s{^\*}{} ? ('$'. $_, '%' . $_, '@' . $_) : $_} @English::COMPLETE_EXPORT;
            open my $fh, '<', $path or die "Cannot open $path: $!";
            while (<$fh>) {
                push @_candidate, m{X<< (.*?) >>}g;
                push @_candidate, m{X<(.*?)>}g;
            }
            close $fh;
            my %tmp;
            @tmp{@_candidate} = ();
            keys %tmp;
        };
    my @variables;
    my $txn = $c->dbh_master->txn_scope();
    $c->dbh_master->do(q{DELETE FROM var});
    for my $name (@candidate) {
        my @dynamic_pod;
	my $perldoc = Pod::Perldoc->new(opt_v => $name);
	eval {
	    $perldoc->search_perlvar([$path], \@dynamic_pod);
	};
	next if not @dynamic_pod;

	push @variables, $name;
        my $pod = join("", "=encoding euc-jp\n\n=over 4\n\n", @dynamic_pod, "=back\n");
        $pod =~ s!L</([a-z]+)>!L<$1|http://perldoc.jp/variable/$1>!g;
        my $html = PJP::M::Pod->pod2html(\$pod);
	$c->dbh_master->insert(
			       var => {
				       name    => $name,
				       version => $version,
				       html    => $html,
				      },
			      );
    }
    $txn->commit();
}

1;
