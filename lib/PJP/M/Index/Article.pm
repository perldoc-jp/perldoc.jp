use strict;
use warnings;
use utf8;
use 5.10.0;

# perl -Ilib -e 'use PJP::M::Index::Module; use PJP; my $c = PJP->bootstrap; PJP::M::Index::Module->generate_and_save($c)'

package PJP::M::Index::Article;
use LWP::UserAgent;
use CPAN::DistnameInfo;
use Log::Minimal;
use URI::Escape qw/uri_escape/;
use JSON;
use File::Spec::Functions qw/catfile/;
use File::Find::Rule;
use version;
use autodie;
use PJP::M::Pod;
use Data::Dumper;
use Regexp::Common qw/URI/;
use PJP::Util qw/slurp/;

sub generate {
    my ($class, $c) = @_;

    # 情報をかきあつめる
    my @files;
    for my $base (map { File::Spec->catdir( $c->assets_dir(), $_) } qw(
        translation/docs/articles/
    )) {
        push @files, $class->_get_files($c, $base) if -d $base;
    }

    my @articles = $class->_generate($c, \@files);

    return  map {
        +{
          name     => $_->{name},
          abstract => $_->{abstract},
          repository => $_->{repository},
          distvname  => $_->{distvname},
          latest_version => 0,
          versions => [],
         }
    } @articles;
}

sub _get_files {
    my ($class, $c, $base) = @_;

    my $repository = do {
        local $_ = $base;
        s!^.+?assets/!!;
        s!^([\w\-.]+)/.+!$1!;
        $_;
    };

    opendir(my $dh, $base);
    my @all_files;
    while (defined(my $e = readdir $dh)) {
        next if $e =~ /^\./;
        next if $e =~ /^CVS$/;

        my (@files) = File::Find::Rule->file()
            ->name(qr/\.(pod|html|md)$/)
            ->in("$base/$e");
        push @all_files, @files;
    }
    map {[$repository, $_]} @all_files;
}

sub _generate {
    my ($class, $c, $files) = @_;

    my @mods;
    foreach my $repo_file (sort {-M $a->[1] <=> -M $b->[1]} @$files) {
        my ($repository, $file) = @$repo_file;
        my $is_pod;
        my ($row, $package, $dist, $distvname, $abstract);
        $distvname = $file;
        $distvname =~ s{^.*?articles/}{};
        if ($file =~ m{^.*?articles/([^/]+)/(?:.*?/)?([^/]+)\.html$}) {
            $is_pod = 0;
            ($package, $dist) = ($1, $2);
            ($dist, $abstract) = $c->abstract_title_description(scalar slurp($file));
        } elsif ($file =~ m{^.*?articles/([^/]+)/(?:.*?/)?([^/]+)\.md$}) {
            $is_pod  = 0;
            ($package, $dist) = ($1, $2);
            ($dist, $abstract) = $c->abstract_title_description_from_md(scalar slurp($file));
        } elsif ($file =~ m{^.*?articles/([^/]+)/(?:.*?/)?([^/]+?)\.pod$}) {
            $is_pod  = 1;
            ($package, $dist) = ($1, $2);
        }
        $row = {
                name       => $dist,
                version    => 0,
                package    => $package,
                distvname  => $distvname,
                repository => $repository,
                abstract   => $abstract,
               };

        if ($is_pod) {
            infof("parsing %s", $file);
            my ($name, $desc) = PJP::M::Pod->parse_name_section($file);
            if ($desc) {
                infof("Japanese Description: %s, %s", $name, $desc);
                $row->{abstract} = $desc;
            }
        }

        push @mods, $row;
    }

    return @mods;
}

1;
