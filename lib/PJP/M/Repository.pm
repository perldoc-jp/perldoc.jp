use strict;
use warnings;
use utf8;

package PJP::M::Repository;
use Encode ();
use File::Spec;
use File::Find::Rule;
use PJP::Util qw/read_command/;

# git の日付をどう解釈するかは全生成物 (年次統計の集計年、RSS の +0900 表記) の
# 前提なので、このモジュールが所有する。--date=iso-local は $ENV{TZ} の壁時計を
# 出すため、呼び出し元の環境に依存させない
use constant TIME_ZONE => 'Asia/Tokyo';

# 翻訳文書として扱うファイルの拡張子。git 由来 (commit_events) と
# readdir 由来 (current_paths, PJP::M::Index::Article) の両方の入口が
# 同じ述語を通らないと、片方だけに存在する形式のファイルが
# 「イベントには有るが現ツリーから消えた」(またはその逆) に化ける
use constant TRANSLATION_FILE_RE => qr/\.(?:pod|html|md)$/;

# このモジュールが返す path と author は decode 済みの文字列。git の出力と
# readdir という別々の入口の生バイトを同じ文字列空間に写すため、境界の decode は
# commit_events / current_paths と、path を突き合わせる他の消費者
# (PJP::M::Index::Article) がここを通す。片方だけ生バイトのままだと、
# 非 ASCII のファイル名で「イベントには有るが現ツリーから消えた」判定が
# 黙って外れる。不正な UTF-8 は decode_utf8 の既定動作で置換文字に倒し、
# 単一コミットの文字化けで databuild 全体が die しないようにする
# (両方の入口が同じ写像を通るので、置換後も突き合わせは成立する)
sub decode_path {
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

  my %paths;
  foreach my $repos (qw/translation/) {
      foreach my $file (File::Find::Rule->file()->name(TRANSLATION_FILE_RE)->in(File::Spec->catdir($c->assets_dir, $repos))) {
          my $rel = decode_path($file);
          $rel =~ s{^.+?assets/}{};
          $rel =~ s{^\Q$repos/\E}{};
          $paths{_rel2path($rel)} = 1;
      }
  }
  return \%paths;
}

# 翻訳イベント (コミット × ファイル) の全列挙。git log の全走査 1 回で、
# 削除・rename により現ツリーから消えた翻訳のイベントも含めて、git log の
# 出力順 (子が親より先 = 配列の先頭側が新しい) のまま返す。真のコミット順を
# 運ぶのはこの順序だけで、date は「いつ起きたか」(年の割当・掲載期間) の
# データであり「どちらが後か」の判定には使わない。git log の既定順は親を
# 子の処理時に初めて走査キューへ入れるため祖先順を常に守り、同一履歴に
# 対して決定的。
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

  # --date=iso-local が出す壁時計の基準。%ENV は子プロセスに渡るので git に効く。
  # 呼び出し元の環境に委ねると、docs/cloud-run.md が案内する手元での再導出を
  # 非 JST のマシンで実行しただけで全イベントの日付がずれ、年境界のコミットが
  # 別の年に落ちた data/years.pl が seed として恒久化してしまう
  local $ENV{TZ} = TIME_ZONE;

  # _file2name で解決できない path の扱いを「現ツリーに在るか」で分ける
  # ための集合 (下のループ内のコメント参照)
  my $current = $class->current_paths($c);

  my @events;
  my (%prev_date, @inverted);
  foreach my $repos (qw/translation/) {
      # コミットの区切りは %x01 (--name-status のファイル行と衝突しない制御文字)。
      # --no-renames は rename を削除+追加の 2 イベントとして出す
      # (旧 path の実績を旧 path のまま残す)。core.quotepath=false は
      # 非 ASCII のファイル名を \xHH に崩さず生バイトで出すため
      my ($date, $author);
      # git log が途中で死んでも読み取りループは EOF と区別できない。不完全な
      # イベント列は data/years.pl / recent feed になり自動コミットで master に
      # 恒久化するため、終了状態の検査は read_command に委ねる
      read_command(
          ['git', '-C', File::Spec->catdir($c->assets_dir, $repos), '-c', 'core.quotepath=false',
           'log', '--no-renames', '--date=iso-local',
           '--pretty=format:%x01%cd%x09%an', '--name-status'],
          sub {
              my $line = shift;
              chomp $line;
              return unless length $line;
              # %an もファイル名も git 由来の非 ASCII バイト列になりうる。未 decode の
              # ままだと Data::Dumper の Useqq がバイト単位の \xHH を吐き、config_do で
              # 読み戻した文字列が不正なバイト列のまま後段の wide 文字列と混ざって
              # 文字化けする
              $line = decode_path($line);
              if ($line =~ s/^\x01//) {
                  # --date=iso-local は上で固定した TZ に変換した壁時計を出す。
                  # オフセットは捨て、以降を JST として扱う
                  ($date, $author) = $line =~ m{^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) [-+]\d{4}\t(.+)$} or die $line;
                  return;
              }
              my ($status, $file) = split /\t/, $line, 2;
              return unless $file =~ TRANSLATION_FILE_RE;
              # 翻訳文書の構成に合わない path (リポジトリ直下の運用文書等) は
              # イベントにしない
              my $rel = _normalize_historical_rel($file) // return;
              # 正規化を通った path は翻訳文書ツリー (docs/, manual/) を名乗って
              # いるので、名前が導出できないのは (a) 履歴にだけ存在する旧構成か
              # (b) 現行の配置規則から外れた新しい置き方のどちらか。(b) を黙って
              # 落とすと、配信はされるのに年次統計と recent feed から欠落し、
              # data/years.pl の自動コミットで欠落が seed に恒久化するため、
              # 現ツリーに存在する path に限りビルドを止める
              my ($name, $in) = eval { _file2name($rel) };
              if (!defined $in) {
                  die "cannot derive a document name from a path that exists in the checkout: $rel\n"
                      if $current->{_rel2path($rel)};
                  return;
              }
              my $path = _rel2path($rel);
              # 走査順は新しい方が先。後から出る (= 祖先側の) イベントの date が
              # 先に出たものより新しければ、コミット順と日時が矛盾している
              push @inverted, "$path: $date (ancestor) > $prev_date{$path} (descendant)"
                  if defined $prev_date{$path} and $date gt $prev_date{$path};
              $prev_date{$path} = $date;
              push @events, {
                              date    => $date,
                              author  => $author,
                              path    => $path,
                              name    => $name,
                              in      => $in,
                              version => _file2version($rel),
                              ($status eq 'D' ? (deleted => 1) : ()),
                             };
              return;
          },
      );
  }
  # committer date は push 元マシンの時計なので、祖先順 (= 上の走査順) と
  # 矛盾しうる。矛盾した履歴では年の割当 (date 由来) と path ごとの最新状態の
  # 判定 (祖先順由来) が食い違い、削除済みの翻訳が年次統計に生き残るなど
  # 誤った導出になる。data/years.pl は自動コミットで恒久化するため、自動で
  # 辻褄を合わせずビルドを止めて履歴を確認させる
  die "commit dates contradict the commit order (ancestry) for these paths:\n"
      . join('', map { "  $_\n" } @inverted)
      . "a skewed clock probably produced them, so the year assignment (by date)\n"
      . "and the latest-state decisions (by ancestry) would disagree in the\n"
      . "derived stats. inspect the history before deriving again.\n"
      if @inverted;

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

  # commit_events は git log の走査順 (子が親より先) なので、path ごとの
  # 初出が最新イベント
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
        $in =~s{-}{::}g;
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
