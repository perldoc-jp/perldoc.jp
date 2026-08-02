use strict;
use warnings;
use utf8;

package PJP::M::Repository;
use Time::Piece;
use Encode ();

sub _assets_dir {
  my $c = shift;
  my $mode_name = $c->mode_name || 'development';
  return $c->config->{'assets_dir'} || die "no assets_dir setting in config/" . $mode_name . '.pl';
}

# checkout に実在するファイルの列挙と path の正規化。recent_data と
# current_paths が同じ規則で path を組み立てないと、「seed にあるが現ツリーから
# 消えた」判定が黙って外れるため 1 箇所にまとめている
sub _repos_files {
  my $assets_dir = shift;

  my @files;
  foreach my $repos (qw/translation/) {
      foreach my $file (File::Find::Rule->file()->name(qr/\.(pod|html|md)$/)->in("$assets_dir$repos")) {
          my $rel = $file;
          $rel =~ s{^.+?assets/}{};
          $rel =~ s{^\Q$repos/\E}{};
          push @files, {
                        repos => $repos,
                        file  => $file,
                        rel   => $rel,
                        path  => ($rel =~ m{^docs} ? $rel : 'docs/modules/' . $rel),
                       };
      }
  }
  return @files;
}

# 現在の checkout に存在する path の集合。create_year_data.pl が
# 「seed には有るが現ツリーから消えた (削除・rename された)」エントリを
# 見分けるのに使う
sub current_paths {
  my ($class, $c) = @_;
  return +{ map { $_->{path} => 1 } _repos_files(_assets_dir($c)) };
}

sub recent_data {
  my ($class, $c, $date, $until) = @_;

  my $assets_dir = _assets_dir($c);

  my @updates;
  my %uniq;

  foreach my $f (_repos_files($assets_dir)) {
      my ($repos, $file) = ($f->{repos}, $f->{file});
      # ファイル名は translation リポジトリ由来の外部入力なので、シェルを
      # 経由せず list 形式で exec する。'--' でオプション解釈も遮断する
      open my $git_fh, '-|', 'git', '-C', "$assets_dir$repos",
          'log', '-1', '--date=iso', '--pretty=%cd -- %an', "--since=$date",
          ($until ? ("--until=$until") : ()), '--', $file
          or die "Cannot run git: $!";
      my $git = do { local $/; <$git_fh> };
      close $git_fh;
      $git or next;
      # %an は git 由来の非 ASCII バイト列になりうるため、ここで decode
      # する (未 decode のままだと Data::Dumper の Useqq がバイト単位の
      # \xHH を吐き、config_do で読み戻した文字列が不正なバイト列のまま
      # 後段の wide 文字列と混ざって文字化けする)。不正な UTF-8 は
      # decode_utf8 の既定動作で置換文字に倒し、単一コミットの文字化けで
      # databuild 全体が die しないようにする
      $git = Encode::decode_utf8($git);
      # --date=iso はコミットに記録された committer 自身のオフセットを
      # そのまま出すため、負のオフセット (-0700 など) も受け付ける
      my ($date, $time, $author) = $git =~m{^(\d{4}-\d{2}-\d{2})( \d{2}:\d{2}:\d{2}) [-+]\d{4} -- (.+)$} or die $git;
      if (not $uniq{$date . $time}{$file}++) {
          my ($name, $in) = _file2name($f->{rel});
          push @updates, {
                          date    => $date . $time,
                          author  => $author,
                          path    => $f->{path},
                          name    => $name,
                          in      => $in,
                          version => _file2version($f->{rel})
                         };
      }
  }
  my %tmp;
  # path のタイブレークで同時刻のエントリの順序を決定的にする
  # (File::Find の走査順は FS 依存で、生成物の diff にノイズが出る)
  @updates = ( sort {($tmp{$b} ||= $b->{date}) cmp ($tmp{$a} ||= $a->{date}) || $a->{path} cmp $b->{path}} @updates );
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
    } elsif ($name =~ s{^manual/([^/]+)}{}) {
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

