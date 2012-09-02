package PJP;
use strict;
use warnings;
use parent qw/Amon2/;
our $VERSION='0.01';
use 5.01000;

use Amon2::Config::Simple;
sub load_config { Amon2::Config::Simple->load(shift) }

use PJP::Cache;
my $cache = PJP::Cache->new();
sub cache { $cache }

use PJP::DBI;
sub dbh {
        my $c = shift;
        my $conf = $c->config->{DB} // die "Missing mandatory configuraion parameter: DB";
        return $c->{db} //= PJP::DBI->connect(@$conf);
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
  if ($html =~ m{<meta\s+name="description"\s+content="([^"]+)">}i) {
    $abstract = $1;
  }
  return ($title, $abstract)
}

1;
