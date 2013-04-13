use strict;
use warnings;
use utf8;

package PJP::M::BuiltinVariable;
use PJP::M::Pod;
use Pod::Perldoc;
use Amon2::Declare;
use English ();

# pod -u perlvar |grep '^X<'
our @VARIABLES = (qw{
  $_ @_ $" $$ $( $) $0 $; $<  $> $a $b $^C $^D ${^ENCODING} %ENV $^F @F ${^GLOBAL_PHASE} $^H %^H @INC %INC
  $^I $^M $^O ${^OPEN} $^P %SIG $^T ${^TAINT} ${^UNICODE} ${^UTF8CACHE} ${^UTF8LOCALE} $^V ${^WIN32_SLOPPY_STAT}
  $^X $1 $& ${^MATCH} $` $` $' ${^POSTMATCH} $+ $^N @+ %+ @- %- $^R ${^RE_DEBUG_FLAGS} ${^RE_TRIE_MAXBUF}
  $ARGV @ARGV ARGV ARGVOUT $/ $\ $| $^A $^L $% $- $: $= $^ $~ ${^CHILD_ERROR_NATIVE} $^E $^S
  $^W ${^WARNING_BITS} $! %! $? $@ $* $[ $] $.}, '$#', '$,');

my %VARIABLES;
@VARIABLES{@VARIABLES, grep {s{^\*}{\$}} @English::COMPLETE_EXPORT} = ();

sub exists {
    my ($class, $name) = @_;
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

    my $txn = $c->dbh_master->txn_scope();
    $c->dbh_master->do(q{DELETE FROM var});
    for my $name (keys %VARIABLES) {
        my @dynamic_pod;
        my $perldoc = Pod::Perldoc->new(opt_v => $name);
        $perldoc->search_perlvar([$path], \@dynamic_pod);

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
