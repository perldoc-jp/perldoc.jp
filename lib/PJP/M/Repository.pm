use strict;
use warnings;
use utf8;

package PJP::M::Repository;
use Encode ();
use File::Find::Rule;

sub _assets_dir {
  my $c = shift;
  my $mode_name = $c->mode_name || 'development';
  return $c->config->{'assets_dir'} || die "no assets_dir setting in config/" . $mode_name . '.pl';
}

# リポジトリ内の相対 path から、data/years.pl や recent feed が使う path 形式を
# 組み立てる。commit_events と current_paths が同じ規則を通らないと、
# 「イベントには有るが現ツリーから消えた」判定が黙って外れるため 1 箇所に
# まとめている
sub _rel2path {
  my $rel = shift;
  return $rel =~ m{^docs} ? $rel : 'docs/modules/' . $rel;
}

# 現在の checkout に存在する path の集合。recent feed が削除・rename 済みの
# 翻訳を載せないためのフィルタに使う
sub current_paths {
  my ($class, $c) = @_;
  my $assets_dir = _assets_dir($c);

  my %paths;
  foreach my $repos (qw/translation/) {
      foreach my $file (File::Find::Rule->file()->name(qr/\.(pod|html|md)$/)->in("$assets_dir$repos")) {
          my $rel = $file;
          $rel =~ s{^.+?assets/}{};
          $rel =~ s{^\Q$repos/\E}{};
          $paths{_rel2path($rel)} = 1;
      }
  }
  return \%paths;
}

# 翻訳イベント (コミット × ファイル) の全列挙。git log の全走査 1 回で、
# 削除・rename により現ツリーから消えた翻訳のイベントも含めて日付の降順で返す。
# ファイルの削除イベントは deleted フラグ付きで返し、扱いは呼び出し側の
# 関心事にする (年次統計は「年内最終イベントが削除」の path をその年に
# 数えない、など)。
#
# 現存ファイルごとの git log (-1 --since -- <path>) で観測しない理由:
# - 削除・rename された翻訳のイベントが一切見えず、年次統計から欠落する
# - 2023 年のリポジトリ再編 (subtree merge) より前から変わっていない path は
#   履歴が merge コミットに簡約され、翻訳者ではなく merge 実行者の日時・
#   author が観測される
# - 現存ファイル数ぶんの git fork が要る
sub commit_events {
  my ($class, $c) = @_;

  my $assets_dir = _assets_dir($c);

  my @events;
  foreach my $repos (qw/translation/) {
      # コミットの区切りは %x01 (--name-status のファイル行と衝突しない制御文字)。
      # --no-renames は rename を削除+追加の 2 イベントとして出す
      # (旧 path の実績を旧 path のまま残す)。core.quotepath=false は
      # 非 ASCII のファイル名を \xHH に崩さず生バイトで出すため
      open my $git_fh, '-|', 'git', '-C', "$assets_dir$repos", '-c', 'core.quotepath=false',
          'log', '--no-renames', '--date=iso-local',
          '--pretty=format:%x01%cd%x09%an', '--name-status'
          or die "Cannot run git: $!";
      my ($date, $author);
      while (my $line = <$git_fh>) {
          chomp $line;
          next unless length $line;
          # %an は git 由来の非 ASCII バイト列になりうるため、ここで decode
          # する (未 decode のままだと Data::Dumper の Useqq がバイト単位の
          # \xHH を吐き、config_do で読み戻した文字列が不正なバイト列のまま
          # 後段の wide 文字列と混ざって文字化けする)。不正な UTF-8 は
          # decode_utf8 の既定動作で置換文字に倒し、単一コミットの文字化けで
          # databuild 全体が die しないようにする
          $line = Encode::decode_utf8($line);
          if ($line =~ s/^\x01//) {
              # --date=iso-local は TZ (databuild では Asia/Tokyo) に変換した
              # 壁時計を出す。オフセットは捨て、以降を JST として扱う
              ($date, $author) = $line =~ m{^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) [-+]\d{4}\t(.+)$} or die $line;
              next;
          }
          my ($status, $file) = split /\t/, $line, 2;
          next unless $file =~ m{\.(?:pod|html|md)$};
          my $rel = _normalize_historical_rel($file) // next;
          # 翻訳文書の構成に合わない path (リポジトリ直下の運用文書等) は
          # イベントにしない
          my ($name, $in) = eval { _file2name($rel) };
          next unless defined $in;
          push @events, {
                          date    => $date,
                          author  => $author,
                          path    => _rel2path($rel),
                          name    => $name,
                          in      => $in,
                          version => _file2version($rel),
                          ($status eq 'D' ? (deleted => 1) : ()),
                         };
      }
      # close はパイプの wait を兼ね、子プロセスの終了状態が $? に入る。
      # git log が途中で死んでも読み取りループは EOF と区別できないため、
      # ここで検査しないと不完全なイベント列が data/years.pl / recent feed に
      # なり、自動コミットで master に恒久化する。子の異常終了だけが原因なら
      # close は $! を 0 にする (perldoc -f close)。list 形式の pipe open は
      # exec 失敗を open 時点で検出できず、それもここで顕在化する
      unless (close $git_fh) {
          die "Cannot read git log output from $assets_dir$repos: $!" if $!;
          die "git log failed in $assets_dir$repos: "
              . ($? & 127 ? 'killed by signal ' . ($? & 127) : 'exit status ' . ($? >> 8));
      }
  }
  # 日付の降順。同時刻・同 path のイベントは git log の出力順 (子コミットが
  # 親より先 = 新しい順) だけが真のコミット順を運ぶため、パース時の添字で
  # その順序を保存する。下流 (YearData の年内最終判定、create_recent の
  # path 初出採用) は配列の先頭側を新しい方として扱うので、ここに author 等の
  # 無関係なキーを挟むと同秒の「追加→削除」が逆転して削除が見えなくなる。
  # 異なる path 同士は path で締めて hash の列挙順に依存させない
  @events = @events[
      sort {
          $events[$b]{date} cmp $events[$a]{date}
              || $events[$a]{path} cmp $events[$b]{path}
              || $a <=> $b
      } 0 .. $#events
  ];
  return \@events;
}

# コミットに記録された当時の path を現在の構造に写像する。2023 年に複数の
# 翻訳リポジトリを subtree merge で寄せ集める再編があり、それより前の
# コミットの path には docs/ prefix が無い (旧 perldoc.jp 由来は core/)。
# Moose 系は現在の配置 (バージョン付き dist ディレクトリ) への機械的な写像が
# 定義できないため落とす (実質 2009 年の翻訳イベントと 2023 年の merge 準備
# コミットだけで、対象年の翻訳者統計には現れない)
sub _normalize_historical_rel {
    my ($rel) = @_;
    return $rel if $rel =~ m{^(?:docs|manual)/};
    return undef if $rel =~ m{^(?:Moose|MooseX|Moose-Doc-JA|MooseX-Getopt-Doc-JA)/};
    return "docs/perl/$1" if $rel =~ m{^core/(.+)$};
    return "docs/$1" if $rel =~ m{^((?:perl|modules|articles)/.+)$};
    return undef;
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
