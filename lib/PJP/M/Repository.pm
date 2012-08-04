use strict;
use warnings;
use utf8;

package PJP::M::Repository;

sub recent_data {
  my ($class, $c, $date) = @_;

  my $config     = $c->config;
  my $mode_name  = $c->mode_name || 'development';

  my $assets_dir = $config->{'assets_dir'} || die "no assets_dir setting in config/" . $mode_name . '.pl';
  my $code_dir   = $config->{'code_dir'}   || die "no code_dir setting in config/"   . $mode_name . '.pl';


  my $cvs = qx{cd ${assets_dir}perldoc.jp/docs/; cvs history -x AM -l -a -D '$date'|sort};
  my @updates;

  1 while $cvs =~ s{^. (\d{4}-\d{2}-\d{2} \d{2}:\d{2}) \+0000 ([^ ]+) +[\d\.]+ +([^ ]+) +([^ ]+)}{
    my ($date, $author, $path) = ($1 . ':00', $2, "$4/$3");
    if ( $path =~ m{^docs} ) {
        my $datetime = Time::Piece->strptime($date, '%Y-%m-%d %H:%M:%S');
        $datetime += 3600 * 9;

        my ($name, $in) = _file2name($path);
        push @updates, {
                        date    => $datetime->strftime('%Y-%m-%d %H:%M:%S'),
                        author  => $author,
                        path    => $path,
                        name    => $name,
                        in      => $in,
                        version => _file2version($path),
                       }
    }
  }em;

  foreach my $repos (qw/Moose-Doc-JA MooseX-Getopt-Doc-JA/) {
    foreach my $file (File::Find::Rule->file()->name('*.pod')->in("$assets_dir$repos")) {
      my $git = qx{cd $assets_dir/$repos/; git log -1 --date=iso --pretty='%cd -- %an' --since='$date'} or next;
      my ($date, $author) = $git =~m{^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) \+\d{4} -- (.+)$} or die $git;
      $file =~s{^.+?assets/}{};
      $file =~s{^\Q$repos/\E}{};
      my ($name, $in) = _file2name($file);
      push @updates, {
                      date    => $date,
                      author  => $author,
                      path    => 'docs/modules/' . $file,
                      name    => $name,
                      in      => $in,
                      version => _file2version($file)
                     };
    }
  }
  my %tmp;
  @updates = ( sort {($tmp{$b} ||= $b->{date}) cmp ($tmp{$a} ||= $a->{date})} @updates );
  return \@updates;
}

sub _file2name {
    my $name = shift;
    my $in;
    if ($name =~ s{^docs/modules/(.+?)-[\d\._]+(?:[-\w]+)?/(?:lib/)?}{}) {
        $in = $1;
        $in =~s{-}{::};
    } elsif ($name =~ s{^docs/(perl|core)/[^/]+/}{}) {
        $in = 'perl';
    } elsif ($name =~ s{^(Moose[^/]*?)}{}) {
        $in = $1;
        $in =~s{-}{::};
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
    } elsif ($name =~ s{^docs/modules/.+-([\d\._]+)/(lib/)?}{}) {
        return $1;
    }
    return '';
}

1;

