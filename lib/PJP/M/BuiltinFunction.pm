use strict;
use warnings;
use utf8;

package PJP::M::BuiltinFunction;
use PJP::M::Pod;
use Pod::Perldoc;
use Amon2::Declare;
use Regexp::Assemble;
use constant FUNCTION_LIST_FILE => ($ENV{PLACK_ENV} and $ENV{PLACK_ENV} eq 'deployment')
                                   ? '/var/lib/jpa/perldoc.jp/code/functions.txt'
                                   : 'functions.txt';
use PJP::Util qw/slurp/;

our @FUNCTIONS = sort split /\n/, slurp(FUNCTION_LIST_FILE);

my %FUNCTIONS;
@FUNCTIONS{@FUNCTIONS} = ();

our @REGEXP;
{
    my $i = 0;
    my @func_re;
    foreach my $func (@FUNCTIONS) {
        push @func_re, $func;
        # to avoid warning 'Complex regular subexpression recursion limit (32766) exceeded'
        if (@func_re > 30) {
            my $ra = Regexp::Assemble->new;
            $ra->add(@func_re);
            $REGEXP[$i++] = $ra->as_string;
            @func_re = ();
        }
    }
    if (@func_re) {
        my $ra = Regexp::Assemble->new;
        $ra->add(@func_re);
        $REGEXP[$i] = $ra->as_string;
    }
}

sub exists {
    my ($class, $name) = @_;
    return exists $FUNCTIONS{$name};
}

sub retrieve {
    my ($class, $name) = @_;
    c->dbh->selectrow_array(q{SELECT version, html FROM func WHERE name=?}, {}, $name);
}

sub generate {
    my ($class, $c) = @_;

    my $path_info = PJP::M::Pod->get_latest_file_path('perlfunc');
    my ($path, $version) = @$path_info;

    my ($encoding, @candidate) = do
        {
            my $_encoding;
            my @_candidate;
            open my $fh, '<', $path or die "Cannot open $path: $!";
            while (<$fh>) {
                $_encoding = $1 and next if m{^=encoding\s+(.+)$};
                my @names = m{C<(.*?)>}g;;
                push @_candidate, map {s{^(tr|s|q|qq|y|m|qr|qx)/+$}{$1}; $_} @names
            }
            close $fh;
            my %tmp;
            @tmp{@_candidate} = ();
            ($_encoding, keys %tmp);
        };
    $encoding ||= 'euc-jp';

    my @functions;
    my $txn = $c->dbh_master->txn_scope();
    $c->dbh_master->do(q{DELETE FROM func});
    for my $name (@candidate) {
        my @dynamic_pod;
        my $perldoc = Pod::Perldoc->new(opt_f => $name);
        eval {
            $perldoc->search_perlfunc([$path], \@dynamic_pod);
        };
        next if not @dynamic_pod;

        push @functions, $name;
        my $pod = join("", "=encoding $encoding\n\n=over 4\n\n", @dynamic_pod, "=back\n");
        $pod =~ s!L</([a-z]+)>!L<$1|http://perldoc.jp/func/$1>!g;
        my $html = PJP::M::Pod->pod2html(\$pod);
        $c->dbh_master->insert(
                               func => {
                                        name => $name,
                                        version => $version,
                                        html => $html,
                                       },
                              );
    }

    open my $fh, '>', FUNCTION_LIST_FILE . '.update' or die "Cannot open " . FUNCTION_LIST_FILE . ".update: $!";
    print $fh join "\n", @functions;
    close $fh;
    chmod 0644, FUNCTION_LIST_FILE . '.update' or die "Cannot chmod " . FUNCTION_LIST_FILE . ".update: $!";
    rename FUNCTION_LIST_FILE . '.update' => FUNCTION_LIST_FILE;
    $txn->commit();
}

1;

