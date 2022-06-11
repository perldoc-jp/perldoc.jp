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

# perlop から検索するものの正規表現
my $OPS_REGEXP = 'tr|s|q|qq|y|m|qr|qx';

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
    return (exists $FUNCTIONS{$name} or $name =~ qr/^$OPS_REGEXP$/);
}

sub retrieve {
    my ($class, $name) = @_;
    c->dbh->selectrow_array(q{SELECT version, html FROM func WHERE name=?}, {}, $name);
}

sub generate {
    my ($class, $c) = @_;

    my $path_info = PJP::M::Pod->get_latest_file_path('perlfunc');
    my ($path, $version) = @$path_info;

    my $path_info_perlop = PJP::M::Pod->get_latest_file_path('perlop');
    my ($perlop_path, $perlop_version) = @$path_info_perlop;

    my ($perlfunc_encoding, @candidate) = do
        {
            my $_encoding;
            my @_candidate;
            open my $fh, '<', $path or die "Cannot open $path: $!";
            while (<$fh>) {
                $_encoding = $1 and next if !defined $_encoding && m{^=encoding\s+(.+)$};
                s{E<sol>}{/}g;
                my @names = m{C<(\-?[a-zA-Z_]+)(?:[^>]+)?>}g;
                push @_candidate, map {s{^($OPS_REGEXP)(?:/+|/STRING/)$}{$1}; $_} @names;
            }
            close $fh;
            my %tmp;
            @tmp{@_candidate} = ();
            ($_encoding, keys %tmp);
        };

    my $perlop_encoding = do
        {
            my $_encoding;
            open my $fh, '<', $perlop_path or die "cannot open $perlop_path: $!";
            while (<$fh>) {
                if (m{^=encoding\s+(.+)$}) {
                    $_encoding = $1;
                    last;
                }
            }
            close $fh;
            $_encoding;
        };

    $perlfunc_encoding ||= 'euc-jp';
    $perlop_encoding   ||= 'euc-jp';

    my @functions;
    my $txn = $c->dbh_master->txn_scope();
    $c->dbh_master->do(q{DELETE FROM func});
    for my $name (@candidate) {
        my $encoding;
        my @dynamic_pod;
        my $perldoc = Pod::Perldoc->new(opt_f => $name);
        my $found_in_perlop = 0;
        if (not $name =~ m{^(?:$OPS_REGEXP)$}) {
            eval {
                $perldoc->search_perlfunc([$path], \@dynamic_pod);
            };
            $encoding = $perlfunc_encoding;
        } else {
            eval {
                $perldoc->search_perlop([$perlop_path], \@dynamic_pod);
            };
            if (@dynamic_pod) {
                $found_in_perlop = 1;
                # search_perlop が search_perlfuncと挙動が違い、=over と =back の後を余計に拾ってしまう
                my ($start_index, $last_index) = (0, 0);
                for (my $i = 0; $i < @dynamic_pod; $i++) {
                    if ($dynamic_pod[$i] =~ m{^=over }) {
                        $start_index = $i;
                        last;
                    }
                }
                for (my $i = @dynamic_pod - 1; $i > $start_index; $i--) {
                    if ($dynamic_pod[$i] =~m{^\s*=back}) {
                        $last_index = $i;
                        last;
                    }
                }
                $encoding = $perlop_encoding;
                @dynamic_pod = @dynamic_pod[$start_index .. $last_index];
            }
        }
        next if not @dynamic_pod;

        push @functions, $name;
        my $pod = join("", "=encoding $encoding\n\n=over 4\n\n", @dynamic_pod, "\n\n=back\n");
        $pod =~ s!L</([a-z]+)>!L<$1|http://perldoc.jp/func/$1>!g;
        my $html = PJP::M::Pod->pod2html(\$pod);
        $c->dbh_master->insert(
                               func => {
                                        name    => $name,
                                        version => $found_in_perlop ? $perlop_version : $version,
                                        html    => $html,
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
