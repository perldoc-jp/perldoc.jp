use strict;
use warnings;
use utf8;

package PJP::M::Repository;
use Time::Piece;

sub recent_data {
  my ($class, $c, $date) = @_;

  my $config     = $c->config;
  my $mode_name  = $c->mode_name || 'development';

  my $assets_dir = $config->{'assets_dir'} || die "no assets_dir setting in config/" . $mode_name . '.pl';
  my $code_dir   = $config->{'code_dir'}   || die "no code_dir setting in config/"   . $mode_name . '.pl';

  my @updates;
  my %uniq;

  foreach my $repos (qw/translation/) {
      foreach my $file (File::Find::Rule->file()->name(qr/\.(pod|html|md)$/)->in("$assets_dir$repos")) {
          my $git = qx{cd $assets_dir/$repos/; git log -1 --date=iso --pretty='%cd -- %an' --since='$date' $file} or next;
          my ($date, $time, $author) = $git =~m{^(\d{4}-\d{2}-\d{2})( \d{2}:\d{2}:\d{2}) \+\d{4} -- (.+)$} or die $git;
          if (not $uniq{$date . $time}{$file}++) {
              $file =~s{^.+?assets/}{};
              $file =~s{^\Q$repos/\E}{};
              my ($name, $in) = _file2name($file);
              push @updates, {
                              date    => $date . $time,
                              author  => $author,
                              path    => ($file =~m{^docs} ? $file : 'docs/modules/' . $file),
                              name    => $name,
                              in      => $in,
                              version => _file2version($file)
                             };
          }
      }
  }
  my %tmp;
  @updates = ( sort {($tmp{$b} ||= $b->{date}) cmp ($tmp{$a} ||= $a->{date})} @updates );
  return \@updates;
}

sub _file2name {
    my $name = shift;
    my $in;
    if ($name =~ s{^docs/modules/(.+?)-v?[\d\._]+(?:[-\w]+)?/(?:lib/)?}{}) {
        $in = $1;
        $in =~s{-}{::};
    } elsif ($name =~ s{^docs/articles/([^/]+)/(?:.+/)?([^/]+)\.(?:pod|html|md)$}{$2}) {
        $in = $1;
    } elsif ($name =~ s{^docs/(perl|core)/[^/]+/}{}) {
        $in = 'perl';
    } elsif ($name =~ s{^wiki/([^/]+)}{}) {
        $in = $1;
    } else {
        die $name;
    }
    $name =~ s{\.pod$}{};
    $name =~ s{/+}{/}g;
    $name =~ s{/}{::}g;
    return ($name, $in);
}

sub _file2version {
    my $name = shift;
    if ($name =~ s{^docs/perl/([^/]+)/}{}) {
        return $1;
    } elsif ($name =~ s{^docs/modules/.+-v?([\d\._]+)/(lib/)?}{}) {
        return $1;
    }
    return '';
}

1;

