package PJP;
use strict;
use warnings;
use feature qw(state);
use parent qw/Amon2/;
our $VERSION='0.01';
use 5.01000;

use PJP::Util qw(markdown_to_html);

use Amon2::Config::Simple;
sub load_config { Amon2::Config::Simple->load(shift) }

use PJP::Cache;
my $cache = PJP::Cache->new();
sub cache { $cache }

use PJP::DBI;
sub dbh {
        my $c = shift;
        my $conf = ($c->config->{DBSlave} || $c->config->{DB}) // die "Missing mandatory configuraion parameter: DB or DBSlave";
        return $c->{db} //= PJP::DBI->connect(@$conf);
}

sub dbh_master {
        my $c = shift;
        my $conf = $c->config->{DB} // die "Missing mandatory configuraion parameter: DB";
        return $c->{db_master} //= PJP::DBI->connect(@$conf);
}

sub assets_dir {
    my $c = shift;
    $c->config->{assets_dir} // die "Missing configuration for assets dir";
}

sub abstract_title_description {
  my ($c, $html) = @_;
  my $title;
  if ($html =~ m{<title>(.*?)</title>}) {
    $title = $1;
  } elsif ($html =~ m{<h1>(.*?)</h1>}) {
    $title = $1;
  }
  my $abstract;
  if ($html =~ m{<meta\s+name=(['"])description\1\s+content=(['"])([^"]+)\2[^>]*>}si) {
    $abstract = $3;
  }
  return ($title, $abstract)
}

sub abstract_title_description_from_md {
  my ($c, $md) = @_;
  my ($title, $abstract)  = $md =~m{^\s*#(.+?)\n(.+?)#}s;

  if ($title =~ m{の翻訳$}) {
    ($title)  = $title =~m{^(.+)の翻訳$};
  } elsif ($title =~ m{翻訳}) {
    ($title)  = $md =~m{^\s*#.+?\n.+?#(.+?)\n}s;
  }
  if ($md =~ m{#\s*[^\s]*翻訳[^\s]*\n(.+?)#}s) {
    ($abstract) = $1;
  }
  if ($abstract) {
    $abstract = markdown_to_html($abstract);
    ($abstract) = $abstract =~ m{^<p>(.+?)</p>};
  }
  if ($abstract) {
    $abstract =~ s{<.*?>}{}g;
  }
  return ($title, $abstract);
}

1;
