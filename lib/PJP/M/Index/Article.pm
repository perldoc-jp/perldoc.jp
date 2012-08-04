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

sub slurp {
    if (@_==1) {
        my ($stuff) = @_;
        open my $fh, '<', $stuff or die "Cannot open file: $stuff";
        do { local $/; <$fh> };
    } else {
        die "not implemented yet.";
    }
}

sub get {
    my ($class, $c) = @_;

    my $fname = $class->cache_path($c);
    unless (-f $fname) {
        die "Missing '$fname'";
    }

    return do $fname;
}

sub cache_path {
    my ($class, $c) = @_;
    return catfile($c->assets_dir(), 'index-article.pl');
}

sub generate_and_save {
    my ($class, $c) = @_;

    my $fname = $class->cache_path($c);

    my @data = $class->generate($c);
    local $Data::Dumper::Terse  = 1;
    local $Data::Dumper::Indent = 1;
    local $Data::Dumper::Purity = 1;

    open my $fh, '>', $fname;
    print $fh Dumper(\@data);
    close $fh;

    return;
}

sub generate {
    my ($class, $c) = @_;

    # 情報をかきあつめる
    my @articles;
    for my $base (map { File::Spec->catdir( $c->assets_dir(), $_) } qw(
        perldoc.jp/docs/articles/
        module-pod-jp/docs/articles/
    )) {
        push @articles, $class->_generate($c, $base) if -d $base;
    }

    return  map {
	+{
	  name     => $_->{name},
	  abstract => $_->{abstract},
	  repository => $_->{repository},
	  distvname  => $_->{distvname},
	  latest_version => 0,
	  versions => [],
	 }
    } @articles
}

sub _generate {
    my ($class, $c, $base) = @_;

    my $repository = do {
        local $_ = $base;
        s!^.+?assets/!!;
        s!^([\w\-.]+)/.+!$1!;
        $_;
    };

    my @mods;
    opendir(my $dh, $base);
    while (defined(my $e = readdir $dh)) {
        next if $e =~ /^\./;
        next if $e =~ /^CVS$/;

        my (@files) = File::Find::Rule->file()
            ->name(qr/\.(pod|html)$/)
            ->in("$base/$e");

	my $is_pod;
	foreach my $file (@files) {
	    my ($row, $package, $dist, $distvname);
	    $distvname = $file;
	    $distvname =~ s{^.*?articles/}{};
	    if ($file =~ m{^.*?articles/([^/]+)/.*?/([^/]+)\.html$}) {
		$is_pod = 0;
		($package, $dist) = ($1, $2);

		my $html = slurp($file);
		if ($html =~ m{<h1>(.*?)</h1>}) {
		    $dist = $1;
		} elsif ($html =~ m{<title>(.*?)</title>}) {
		    $dist = $1;
		}
	    } elsif ($file =~ m{^.*?articles/([^/]+)/([^/]+?)\.pod$}) {
		$is_pod  = 1;
		($package, $dist) = ($1, $2);
	    }
	    $row = {
		    name       => $dist,
		    version    => 0,
		    package    => $package,
		    distvname  => $distvname,
		    repository => $repository,
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
    }

    return @mods;
}

1;

