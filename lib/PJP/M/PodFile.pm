use strict;
use warnings;
use utf8;

package PJP::M::PodFile;
use Amon2::Declare;
use File::Spec::Functions qw/abs2rel catfile catdir/;
use File::Find::Rule;
use PJP::M::Pod;
use Log::Minimal;
use File::Basename;

sub slurp {
    my ($class, $path) = @_;
    my $c = c();

    # インデックスされてるか確認する
    my ($cnt) = $c->dbh->selectrow_array(q{SELECT COUNT(*) FROM pod WHERE path=?}, {}, $path);
    return undef unless $cnt;

    my ($fullpath);
    if ($path =~s{modules/(Moose[^/]*)}{$1}) {
        my $module_name = $1;
        ($fullpath) = glob(catdir($c->assets_dir(), $module_name . '-Doc-JA', $path));
    } else {
        ($fullpath) = glob(catdir($c->assets_dir(), '*', 'docs', $path));
    }
    return undef unless -f $fullpath;

    open my $fh, '<', $fullpath or die "Cannot open file: $fullpath";
    return scalar(do { local $/; <$fh> });
}

sub retrieve {
        my ($class, $path) = @_;

        my $c = c();
        $c->dbh->single(
                'pod' => {
                        path => $path,
                },
        );
}

sub other_versions {
        my ($class, $package) = @_;
        my $c = c();
        @{$c->dbh->selectall_arrayref(q{SELECT distvname, path FROM pod WHERE package=?}, {Slice => {}}, $package)};
}

sub get_latest {
        my ($class, $package) = @_;

        my $c = c();
    my @versions =
      map  { $_->[0] }
      reverse sort { $a->[1] <=> $b->[1] }
      map  { [ $_, eval { version->parse($_) } || 0 ] } map { @$_ } @{
        $c->dbh->selectall_arrayref( q{SELECT distvname FROM pod WHERE package=?},
            {}, $package )
      };
        unless (@versions) {
                infof("Any versions not found in database: %s", $package);
                return undef;
        }

        my($path) = $c->dbh->selectrow_array(
                q{SELECT path FROM pod WHERE package=? AND distvname=?}, {}, $package, $versions[0]
        );
        return $path;
}

sub search_by_distvname {
        my ($class, $distvname) = @_;
        my $c = c();
        @{ $c->dbh->selectall_arrayref(q{SELECT package, path, description FROM pod WHERE distvname=? ORDER BY package}, {Slice => {}}, $distvname) };
}

sub search_by_packages {
        my ($class, $packages) = @_;
        my $c = c();
        my $place_holder = join ',', (('?') x @$packages);
        @{ $c->dbh->selectall_arrayref(qq{SELECT path, package, description FROM pod WHERE package in ($place_holder) ORDER BY package}, {Slice => {}}, @$packages) };
}

sub search_by_packages_like {
        my ($class, $packages) = @_;
        my $c = c();
        my $where = join ' or ', (('package like ?') x @$packages);
        @{ $c->dbh->selectall_arrayref(qq{SELECT path, package, description FROM pod WHERE $where ORDER BY package}, {Slice => {}}, @$packages) };
}

sub generate {
        my ($class, $c) = @_;

        my $txn = $c->dbh->txn_scope();
        $c->dbh->do(q{DELETE FROM pod});
        my @bases = (glob(catdir($c->assets_dir(), '*', 'docs')),
                     glob(catdir($c->assets_dir(), 'Moose-Doc-JA')),
                     glob(catdir($c->assets_dir(), 'MooseX-Getopt-Doc-JA')),
                    );
        for my $base (@bases) {
                my $repository = $base;
                $repository =~ s{^.+?/assets/}{};
                $repository =~ s{^([\w\-.]+)/.+}{$1};

                my @files = File::Find::Rule->file()
                    ->name('*.pod')
                    ->in($base);

                for my $file (@files) {
                        $class->generate_one_file($c, $file, $base, $repository);
                }
        }
        $txn->commit;
}

sub generate_one_file {
        my ($class, $c, $file, $base, $repository) = @_;
        infof("Processing: %s", $file);
        my $args = $c->cache->file_cache(
                "path:26",
                $file,
                sub {
                    my $html = PJP::M::Pod->pod2html($file);
                    my $relpath = abs2rel( $file, $base );
                    my ( $package, $description ) =
                      PJP::M::Pod->parse_name_section($file);
                    if ( !defined $package ) {
                        warnf("Cannot get package name from %s", $file);
                        $package = $relpath;
                        $package =~ s/\.pod$//;
                        $package =~ s!^modules/!!;
                    }
                    ( my $distvname = $relpath ) =~ s!^modules/!!;

                    if ($repository =~ m{^Moose}) {
                        $relpath = 'modules/' . $relpath;
                    }

                    $distvname =~ s!^perl/!!;
                    $distvname =~ s!/.+!!;
                    +{
                        path        => $relpath,
                        package     => $package,
                        description => $description,
                        distvname   => $distvname,
                        html        => $html,
                    };
                }
        );
        $c->dbh->replace(
                pod => +{
                        repository => $repository,
                        %$args
                },
        );
}

1;

