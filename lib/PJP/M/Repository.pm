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

# git の日付をどう解釈するかは全生成物 (年次統計の集計年、RSS の +0900 表記) の
# 前提なので、このモジュールが所有する。--date=iso-local は $ENV{TZ} の壁時計を
# 出すため、呼び出し元の環境に依存させない
use constant TIME_ZONE => 'Asia/Tokyo';

# このモジュールが返す path と author は decode 済みの文字列。git の出力と
# readdir という別々の入口の生バイトを同じ文字列空間に写すため、境界の decode は
# commit_events / current_paths の両方がここを通す。片方だけ生バイトのままだと、
# 非 ASCII のファイル名で「イベントには有るが現ツリーから消えた」判定が
# 黙って外れる。不正な UTF-8 は decode_utf8 の既定動作で置換文字に倒し、
# 単一コミットの文字化けで databuild 全体が die しないようにする
# (両方の入口が同じ写像を通るので、置換後も突き合わせは成立する)
sub _decode {
  return Encode::decode_utf8($_[0]);
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
          my $rel = _decode($file);
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

  # --date=iso-local が出す壁時計の基準。%ENV は子プロセスに渡るので git に効く。
  # 呼び出し元の環境に委ねると、docs/cloud-run.md が案内する手元での再導出を
  # 非 JST のマシンで実行しただけで全イベントの日付がずれ、年境界のコミットが
  # 別の年に落ちた data/years.pl が seed として恒久化してしまう
  local $ENV{TZ} = TIME_ZONE;

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
          # %an もファイル名も git 由来の非 ASCII バイト列になりうる。未 decode の
          # ままだと Data::Dumper の Useqq がバイト単位の \xHH を吐き、config_do で
          # 読み戻した文字列が不正なバイト列のまま後段の wide 文字列と混ざって
          # 文字化けする
          $line = _decode($line);
          if ($line =~ s/^\x01//) {
              # --date=iso-local は上で固定した TZ に変換した壁時計を出す。
              # オフセットは捨て、以降を JST として扱う
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

# 現ツリーに存在するのに、最新イベントが削除になっている path を検出して die する。
#
# git log --name-status は merge コミットの diff を出さない。master で削除された
# path を、削除より前から分岐していたブランチの merge が復活させると
# (modify/delete の衝突を「残す」で解決した場合など)、復活そのものはイベントに
# ならず、その path の最新イベントは過去の削除のままになる。この状態では
# - 年次統計 (PJP::M::YearData) が、生きている翻訳をその年から落とす
# - recent feed が、生きている翻訳を削除者の名前と日時で載せる
# となり、しかも data/years.pl はデプロイ成功後に master へ自動コミットされて
# 次回ビルドの seed になるため、誤った導出がそのまま恒久化する。
#
# 履歴の形を見ないと正しい観測方法を決められない (git log に -m 等を足して
# merge の diff を出す方法は、2023 年の subtree merge を含む全 merge の
# 取り込みファイルを merge 実行者の名義で再観測してしまい、翻訳者の帰属を
# 壊す) ため、自動で辻褄を合わせずビルドを止める。
sub assert_no_shadowed_deletions {
  my ($class, $c, $events) = @_;

  my $current = $class->current_paths($c);

  # commit_events は日付の降順なので、path ごとの初出が最新イベント
  my %newest;
  $newest{$_->{path}} //= $_ for @$events;

  my @shadowed = sort grep { $newest{$_}{deleted} && $current->{$_} } keys %newest;
  return unless @shadowed;

  die "these paths exist in the checkout but their newest event is a deletion:\n"
      . join('', map { "  $_ (deleted at $newest{$_}{date})\n" } @shadowed)
      . "a merge commit probably restored them (git log --name-status does not\n"
      . "show merge diffs), so the derived stats and feed would treat live\n"
      . "translations as deleted. inspect the history before deriving again.\n";
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
