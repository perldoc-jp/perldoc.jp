use strict;
use warnings;
use utf8;

package PJP::M::Repository;
use Encode ();
use File::Spec;
use File::Find::Rule;
use POSIX::strftime::Compiler ();
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

# RFC 822 の日時。曜日・月名は英語であることが要求されるので、実行環境の
# ロケールを見ない POSIX::strftime::Compiler で組む ($t は JST の壁時計)。
#
# decode_path と同じくプレーン関数なので、外からは
# PJP::M::Repository::format_rfc822_jst($t) と完全修飾で呼ぶこと。
# ->format_rfc822_jst($t) と書くとクラス名が第 1 引数に入って $t が落ちる
sub format_rfc822_jst {
    my ($t) = @_;
    return POSIX::strftime::Compiler::strftime(
        '%a, %d %b %Y %H:%M:%S +0900',
        $t->sec, $t->min, $t->hour, $t->mday, $t->mon - 1, $t->year - 1900);
}

# assets_dir からの相対 path。ファイルとディレクトリの両方を受ける。
#
# 文字列置換で assets/ より前を削る方式 (s!^.+?assets/!!) は、祖先の
# ディレクトリ名にも assets/ があると切りすぎる。~/assets/assets/translation を
# checkout にすると 'assets/translation/...' ではなく 'translation/...' になり、
# repository 名が 1 つずれる。逆に assets_dir の path 自体に 'assets' という
# component が無い環境 (テストの tempdir 等) では 1 文字も削れない
sub assets_rel {
  my ($c, $path) = @_;
  my $rel = File::Spec->abs2rel($path, $c->assets_dir);
  # assets_dir の外を指していたら止める。/^\.\./ で見ると '..foo' のような
  # 合法な名前まで拒否するので、path component がちょうど '..' かを見る。
  # これは字面上の包含で、symlink を解決した実体の包含までは保証しない
  my ($first) = File::Spec->splitdir($rel);
  die "path is outside of assets_dir: $path"
    if defined $first && $first eq File::Spec->updir;
  return $rel;
}

# assets_dir 直下のどの checkout に属するか (= 生成物の repository 欄)
sub repository_of {
  my ($c, $path) = @_;
  return (File::Spec->splitdir(assets_rel($c, $path)))[0];
}

# このモジュールが返す path と author は decode 済みの文字列。git の出力と
# readdir という別々の入口の生バイトを同じ文字列空間に写すため、境界の decode は
# commit_events / current_paths と、path を突き合わせる他の消費者
# (PJP::M::Index::Article) がここを通す。片方だけ生バイトのままだと、
# 非 ASCII のファイル名で「イベントには有るが現ツリーから消えた」判定が
# 黙って外れる。
#
# 不正な UTF-8 は置換文字に倒さず die する。置換は異なるバイト列 (\xFF と
# \xFE と \xC0\xAF 等) を同じ path に潰すため、別々のファイルのイベントが
# 混ざり、現ツリーとの突き合わせも「両側が同じ誤りに潰れる」ことで素通りする。
# 実在しない path が recent feed のリンクにもなる。
sub decode_path {
  return Encode::decode('UTF-8', $_[0], Encode::FB_CROAK | Encode::LEAVE_SRC);
}

# リポジトリ内の相対 path から、data/years.pl や recent feed が使う path 形式を
# 組み立てる。commit_events と current_paths が同じ規則を通らないと、
# 「イベントには有るが現ツリーから消えた」判定が黙って外れるため 1 箇所に
# まとめている
sub _rel2path {
  my $rel = shift;
  return $rel =~ m{^docs} ? $rel : 'docs/modules/' . $rel;
}

# production の translation checkout から配信対象として取り込む path の集合
# (docs/ 配下)。recent feed が削除・rename 済みの翻訳を載せないためのフィルタに使う。
#
# checkout 全体ではなく docs/ に限るのは、配信されるのがそこだけだから。
# PJP::M::PodFile は assets/*/docs しか読まず (generate も本文の読み出しも)、
# .md の route は articles/ 専用なので、リポジトリ直下の manual/ や旧構成の
# ディレクトリは DB にも入らず URL も無い。それらを live として数えると、
# recent feed とトップページに 404 になる URL が載る。
sub current_paths {
  my ($class, $c) = @_;

  my %paths;
  foreach my $repos (qw/translation/) {
      my $base = File::Spec->catdir($c->assets_dir, $repos, 'docs');
      foreach my $file (File::Find::Rule->file()->name(TRANSLATION_FILE_RE)->in($base)) {
          # base からの相対で切り出す。文字列置換で assets/ より前を削る方式は、
          # 祖先のディレクトリ名にも assets/ があると切りすぎる
          my $rel = 'docs/' . decode_path(File::Spec->abs2rel($file, $base));
          $paths{_rel2path($rel)} = 1;
      }
  }
  return \%paths;
}

# 翻訳イベント (コミット × ファイル) の全列挙。git log の全走査 1 回で、
# 削除・rename により現ツリーから消えた翻訳のイベントも含めて、git log の
# 出力順 (配列の先頭側が新しい) のまま返す。真のコミット順を運ぶのはこの
# 順序だけで、date は「いつ起きたか」(年の割当・掲載期間) のデータであり
# 「どちらが後か」の判定には使わない。
#
# --date-order は「祖先を全ての子より先に出さない」ことだけを保証し、並行
# ブランチどうしの前後は日時で決まる (同じ path を並行して編集した履歴では
# 日時が新しい側を最新として採る近似)。
#
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

  # --date=iso-local が出す壁時計の基準。%ENV は子プロセスに渡るので git に効く
  local $ENV{TZ} = TIME_ZONE;

  my @events;
  foreach my $repos (qw/translation/) {
      # コミットの区切りは %x01 (--name-status のファイル行と衝突しない制御文字)。
      # --no-renames は rename を削除+追加の 2 イベントとして出す
      # (旧 path の実績を旧 path のまま残す)。core.quotepath=false は
      # 非 ASCII のファイル名を \xHH に崩さず生バイトで出すため
      my ($date, $author);
      read_command(
          ['git', '-C', File::Spec->catdir($c->assets_dir, $repos), '-c', 'core.quotepath=false',
           'log', '--date-order', '--no-renames', '--date=iso-local',
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
              # 翻訳文書の構成に合わない path (リポジトリ直下の運用文書等) や、
              # 名前が導出できない path はイベントにしない
              my $rel = _normalize_historical_rel($file) // return;
              my ($name, $in) = eval { _file2name($rel) };
              return if !defined $in;
              push @events, {
                              date    => $date,
                              author  => $author,
                              path    => _rel2path($rel),
                              name    => $name,
                              in      => $in,
                              version => _file2version($rel),
                              ($status eq 'D' ? (deleted => 1) : ()),
                             };
              return;
          },
      );
  }
  return \@events;
}

# 走査順の初出 = その path の最新イベント。この対応付けは commit_events の
# 走査順の契約 (配列の先頭側が新しい) に依存しているので、契約を所有する
# このモジュールに置き、消費者はここを通す
sub latest_events_by_path {
  my ($class, $events) = @_;

  my %latest;
  $latest{$_->{path}} //= $_ for @$events;
  return \%latest;
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
    my $ext = TRANSLATION_FILE_RE;
    my $in;
    if ($name =~ s{^docs/modules/(.+?)-v?[\d\._]+(?:[-\w]+)?/(?:lib/)?}{}) {
        $in = $1;
        $in =~s{-}{::}g;
    } elsif ($name =~ s{^docs/articles/([^/]+)/(?:.+/)?([^/]+)$ext}{$2}) {
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
