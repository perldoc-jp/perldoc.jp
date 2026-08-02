use strict;
use warnings;
use utf8;
use feature qw(state);

package PJP::M::PodFile;
use Amon2::Declare;
use File::Spec::Functions qw/abs2rel catfile catdir/;
use File::Find::Rule;
use PJP::M::Pod;
use Log::Minimal;
use File::Basename;
use version;
use PJP::M::Index::Article;
use PJP::M::BuiltinFunction;
use PJP::Util qw(markdown_to_html);

sub slurp {
    my ($class, $path) = @_;
    my $c = c();

    # インデックスされてるか確認する
    my ($cnt) = $c->dbh->selectrow_array(q{SELECT COUNT(*) FROM pod WHERE path=?}, {}, $path);
    return undef unless $cnt;

    my ($fullpath) = glob(catdir($c->assets_dir(), '*', 'docs', $path));
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

# distvname を比較可能な version 値にする。版の比較はこの関数に一本化する
# (other_versions / get_latest / script/create_docs_json.pl が同じ選択をする)。
# バージョンを持たない distvname (articles の README や ppc 文書等) は croak
# せず最古扱いにする。croak だと無版の文書が混在する package (github.com) で
# 版選択そのものができなくなる
sub _version {
    my ($v) = @_;
    $v =~ s{^.+?-(?=\d)}{};
    $v =~ s{\-RC\d+$}{}i;
    $v =~ s{^.+?-(v[\d\.]+)$}{$1}i;
    return eval { version->new($v) } // version->new(0);
}

sub other_versions {
        my ($class, $package) = @_;
        my $c = c();
        # 同値の版は path (PRIMARY KEY) でタイブレークし、並びを行順に依存させない
        if ($package =~ m{^perl.*?delta$}) {
            sort { _version($b->{distvname}) <=> _version($a->{distvname}) || $b->{path} cmp $a->{path} }
              grep {$_->{package} =~ m{^perl.*?delta$}}
                @{$c->dbh->selectall_arrayref(q{SELECT distvname, path, package FROM pod WHERE package like 'perl%delta'}, {Slice => {}})};
        } else {
            sort { _version($b->{distvname}) <=> _version($a->{distvname}) || $b->{path} cmp $a->{path} }
              @{$c->dbh->selectall_arrayref(q{SELECT distvname, path FROM pod WHERE package=?}, {Slice => {}}, $package)};
        }
}

sub get_latest {
        my ($class, $package) = @_;

        my $c = c();
        my ($where_operator, $search_package);
	my $search_column = 'package';
	if ($package eq 'perldelta') {
	  ($where_operator, $search_package) = ('like', 'perl%delta');
	} elsif ($package =~m{perl5(\d+)delta}) {
	  $search_column = 'path';
	  ($where_operator, $search_package) = ('like', "%/$package.pod");
	} else {
	  ($where_operator, $search_package) = ('=', $package);
	}

    # 版の比較は _version に一本化する。version->parse の直書きは
    # HTTP-Message-6.03 のような distvname が軒並み parse 失敗で 0 になり、
    # 選択が DB の行順 (= スキーマやインデックスの走査順) に依存してしまう。
    # 同値は distvname / package の降順で締めて、結果を常に決定的にする
        my %sort_tmp;
    my @versions =
      sort  { ($sort_tmp{$b->[0]} //= _version($b->[0])) <=> ($sort_tmp{$a->[0]} //= _version($a->[0])) || $b->[0] cmp $a->[0] || $b->[1] cmp $a->[1] } @{
        $c->dbh->selectall_arrayref( qq{SELECT distvname,package FROM pod WHERE $search_column $where_operator ?},
            {}, $search_package )
      };
        unless (@versions) {
                debugf("Any versions not found in database: %s", $search_package);
                return undef;
        }

        my($path) = $c->dbh->selectrow_array(
                q{SELECT path FROM pod WHERE package=? AND distvname=?}, {}, $versions[0]->[1], $versions[0]->[0]
        );
        return $path;
}

sub get_latest_pod {
    my $class = shift;
    my ($package, $pod_path);

    if (@_ == 1) {
        ($pod_path) = @_;
        $package  = $pod_path;
        $package  =~ s{\.pod}{};
    } else {
        ($package, $pod_path) = @_;
        $package =~s{-}{::}g;
        $pod_path =~ s{$package-[^/]+}{$package\%};
    }

    my $c = c();
    my $pod = $c->dbh->single('pod',
                              {
                               package => $package,
                               path    => {'like' => '%' . $pod_path},
                              },
                              {
                               order_by => ['distvname desc'],
                              }
                             );
    return $pod;
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
        @{ $c->dbh->selectall_arrayref(qq{SELECT path, package, description, distvname FROM pod WHERE package in ($place_holder) ORDER BY package, distvname desc}, {Slice => {}}, @$packages) };
}

sub search_by_packages_like {
        my ($class, $packages) = @_;
        my $c = c();
        my $where = join ' or ', (('package like ?') x @$packages);
        @{ $c->dbh->selectall_arrayref(qq{SELECT path, package, description, distvname FROM pod WHERE $where ORDER BY package, distvname desc}, {Slice => {}}, @$packages) };
}

sub generate {
        my ($class, $c) = @_;

        my $txn = $c->dbh_master->txn_scope();
        $c->dbh_master->do(q{DELETE FROM pod});
        my @bases = (glob(catdir($c->assets_dir(), '*', 'docs')));
        for my $base (@bases) {
                my $repository = $base;
                my $extention_exp;
                if ($repository =~ s{^.+?/assets/}{}) {
                    $extention_exp = qr/\.(pod|html|md)$/;
                } else {
                    $extention_exp = '*.pod';
                }
                $repository =~ s{^([\w\-.]+)/.+}{$1};

                my @files = File::Find::Rule->file()
                    ->name($extention_exp)
                    ->in($base);
                for my $file (@files) {
                    eval {
                        if ($file =~ m{\.pod$}) {
                            $class->generate_one_file($c, $file, $base, $repository);
                        } elsif ($file =~ m{\.md$}) {
                            $class->generate_one_file_md($c, $file, $base, $repository);
                        } else {
                            $class->generate_one_file_html($c, $file, $base, $repository);
                        }
                    };
                    if ($@) {
                      warn '===============================================';
                      warn "cannot generate: $file ($@)";
                      warn '===============================================';
                    }
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
                    if ($file =~ m{/perlfunc\.pod$}) {
                        $html = PJP::M::BuiltinFunction->linkify_functions($html);
                    }
                    my $relpath = abs2rel( $file, $base );
                    my ( $package, $description ) =
                      PJP::M::Pod->parse_name_section($file);
                    if ( !defined $package ) {
                        warnf("Cannot get package name from %s", $file);
                        $package = $relpath;
                        $package =~ s/\.pod$//;
                        $package =~ s!^modules/!!;
                        $package =~ s!^articles/!!;
                    }
                    ( my $distvname = $relpath ) =~ s!^(modules|articles)/!!;

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
        $c->dbh_master->replace(
                pod => +{
                        repository => $repository,
                        %$args
                },
        );
}

# it is not pod, but html ...
sub generate_one_file_html {
        my ($class, $c, $file, $base, $repository) = @_;
        infof("Processing: %s", $file);
        my $args = $c->cache->file_cache(
                "path:26",
                $file,
                sub {
                    my $html = PJP::M::Index::Article::slurp($file);
                    my $relpath = abs2rel( $file, $base );
                    my ($package, $distvname) = $relpath =~ m{^articles/([^/]+)/(?:.*?/)?([^/]+)\.html$};

                    $package or die "cannot get package name: $relpath";

                    $distvname =~ s!/.+!!;
                    +{
                        path        => $relpath,
                        package     => $package,
                        distvname   => $distvname,
                        html        => $html,
                    };
                }
        );
        $c->dbh_master->replace(
                pod => +{
                        repository => $repository,
                        %$args
                },
        );
}

# it is not pod, but md ...
sub generate_one_file_md {
        my ($class, $c, $file, $base, $repository) = @_;
        infof("Processing: %s", $file);
        my $args = $c->cache->file_cache(
                "path:26",
                $file,
                sub {
                    my $md_src = PJP::M::Index::Article::slurp($file);
                    my $relpath = abs2rel( $file, $base );
                    my ($package, $distvname) = $relpath =~ m{^articles/([^/]+)/(?:.*?/)?([^/]+)\.md$};

                    $package or die "cannot get package name: $relpath";

                    my $html = markdown_to_html($md_src);

                    $distvname =~ s!/.+!!;
                    +{
                        path        => $relpath,
                        package     => $package,
                        distvname   => $distvname,
                        html        => $html,
                    };
                }
        );
        $c->dbh_master->replace(
                pod => +{
                        repository => $repository,
                        %$args
                },
        );
}

1;

