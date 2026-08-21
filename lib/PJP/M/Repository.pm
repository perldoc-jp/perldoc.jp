use strict;
use warnings;
use utf8;

package PJP::M::Repository;
use Encode ();
use File::Spec;
use File::Find::Rule;
use Time::Piece ();
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

# 未来日時のイベントを許す幅。コミットする側の時計のわずかな進みは通し、
# 明らかな誤設定 (年単位のずれ) は下の検査で止める
use constant CLOCK_SKEW_SLACK => 10 * 60;

# 現在時刻 (epoch)。テストから固定するために括り出してある。
# JST は年間を通じて UTC+9 なので、壁時計は epoch + 9h を UTC として読めば
# よく、$ENV{TZ} の変更が localtime に反映されるかに依存しない
our $NOW_EPOCH;
sub _now_jst {
  return Time::Piece->gmtime(($NOW_EPOCH // time) + 9 * 3600);
}

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

# 履歴上の path を現在の構造へ写す _normalize_historical_rel が書き換える先頭
# ディレクトリ。現ツリーにこれらがあると canonical path が現行配置と衝突する
use constant LEGACY_TOPLEVEL_DIRS => qw/modules perl articles core/;

# 翻訳イベント (コミット × ファイル) の全列挙。git log の全走査 1 回で、
# 削除・rename により現ツリーから消えた翻訳のイベントも含めて、git log の
# 出力順 (配列の先頭側が新しい) のまま返す。真のコミット順を運ぶのはこの
# 順序だけで、date は「いつ起きたか」(年の割当・掲載期間) のデータであり
# 「どちらが後か」の判定には使わない。
#
# --date-order が保証するのは「祖先を全ての子より先に出さない」ことだけで、
# それ以外は「今出せるコミットのうち日時が新しいものを優先する」ヒューリス
# ティック。並行ブランチどうしの前後は日時に依存するため、同じ path を並行
# して編集した履歴では「日時が新しい側」が最新として採られる (どちらが真に
# 最終状態かは merge の解決内容が決めるので、この採用は近似)。祖先が子より
# 先に出ることは無いので、時計の巻き戻ったコミットは下の逆転検査に必ず
# 引っかかり、黙って誤った最新状態が採られることはない。
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
              # core.quotepath=false でも、タブ・改行・引用符・バックスラッシュを
              # 含む path は C 形式でクォートされて出る。末尾が引用符になるので
              # 拡張子の述語にも一致せず、黙ってイベントから落ちる。docs/ 配下の
              # 翻訳なら現ツリーには在るのにイベントだけが欠けた状態になり、
              # 突き合わせが静かにずれる。現ツリーには該当が無いので、
              # 出てきたらビルドを止めて気づかせる
              die "git reported a C-quoted path; this build cannot map it to the checkout: $file\n"
                  if $file =~ /^"/;
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
              # --date-order の走査順では、後から出るイベントは先に出たものの
              # 祖先であるか、並行ブランチ上の (日時が古い) イベントのどちらか。
              # どちらにせよ後から出たものの date が先のものより新しければ、
              # 走査順と日時が矛盾している
              push @inverted, "$path: $date (later output) > $prev_date{$path} (earlier output)"
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
  # committer date は push 元マシンの時計なので、走査順と矛盾しうる。矛盾した
  # 履歴では年の割当 (date 由来) と path ごとの最新状態の判定 (走査順由来) が
  # 食い違い、削除済みの翻訳が年次統計に生き残るなど誤った導出になる。
  # data/years.pl は自動コミットで恒久化するため、自動で辻褄を合わせず
  # ビルドを止めて履歴を確認させる
  die "commit dates contradict the traversal order for these paths:\n"
      . join('', map { "  $_\n" } @inverted)
      . "a skewed clock probably produced them, so the year assignment (by date)\n"
      . "and the latest-state decisions (by traversal order) would disagree in the\n"
      . "derived stats. inspect the history before deriving again.\n"
      if @inverted;

  _assert_no_future_dates(\@events);

  return \@events;
}

# 未来日時のイベントを弾く。壁時計はこの検査にしか使わないので、生成物の
# 内容は従来どおり translation の履歴だけで決まる (決定性は保たれる)。
#
# 誤って未来日時が付いたコミットが 1 件でも混ざると、そこが最新イベントに
# なって対象年 (= 最新イベントの前年) と recent feed の掲載期間ごと未来へ動き、
# 本来まだ再導出すべき年が seed 側へ凍結される。特に年をまたぐずれは、
# 数分のずれでも対象年を 1 年進めてしまうため、slack の内側でも拒否する
sub _assert_no_future_dates {
  my ($events) = @_;

  my $now      = _now_jst();
  my $limit    = Time::Piece->gmtime($now->epoch + CLOCK_SKEW_SLACK)->strftime('%Y-%m-%d %H:%M:%S');
  my $this_year = $now->year;

  my @future = sort map { $_->{date} }
      grep { $_->{date} gt $limit or substr($_->{date}, 0, 4) > $this_year } @$events;
  return unless @future;

  die "these commit dates are in the future (now is @{[ $now->strftime('%Y-%m-%d %H:%M:%S') ]} JST):\n"
      . join('', map { "  $_\n" } @future)
      . "a skewed clock probably produced them, and the newest event decides both\n"
      . "the target year and the recent feed window. inspect the history before\n"
      . "deriving again.\n";
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

# 現ツリーの翻訳が、イベント列の上でも生きているものとして観測できることを
# 確かめて die する。あわせて旧構成のディレクトリが復活していないことも見る
# (_assert_no_legacy_layout)。
#
# 観測の破れ方は 2 つあり、どちらも git log --name-status が
# merge コミットの diff を出さないことに由来する。
#
# (a) 最新イベントが削除: master で削除された path を、削除より前から分岐して
#     いたブランチの merge が復活させると (modify/delete の衝突を「残す」で
#     解決した場合など)、復活そのものはイベントにならず、その path の最新
#     イベントは過去の削除のままになる。
# (b) イベントが 1 件も無い: merge の衝突解決でだけ作られたファイル (どちらの
#     親にも無い新規ファイル) は、その後変更されるまで履歴に一切現れない。
#
# どちらの状態でも
# - 年次統計 (PJP::M::YearData) が、生きている翻訳をその年から落とす
# - recent feed が、生きている翻訳を載せない (または削除者の名前と日時で載せる)
# となり、しかも data/years.pl はデプロイ成功後に master へ自動コミットされて
# 次回ビルドの seed になるため、誤った導出がそのまま恒久化する。
#
# 履歴の形を見ないと正しい観測方法を決められない (git log に -m 等を足して
# merge の diff を出す方法は、2023 年の subtree merge を含む全 merge の
# 取り込みファイルを merge 実行者の名義で再観測してしまい、翻訳者の帰属を
# 壊す) ため、自動で辻褄を合わせずビルドを止める。
#
# なお (b) の path が後で編集されればイベントは現れるので、この検査は通る。
# その場合も merge 時点の作成イベントだけは欠けたままで、初出の年と作成者は
# 後続の編集にずれる。これは履歴からは復元できない曖昧さとして受け入れている。
sub assert_current_paths_observable {
  my ($class, $c, $events) = @_;

  $class->_assert_no_legacy_layout($c);

  my $current = $class->current_paths($c);
  my $latest  = $class->latest_events_by_path($events);

  my @shadowed = sort grep { $latest->{$_}{deleted} && $current->{$_} } keys %$latest;
  die "these paths exist in the checkout but their newest event is a deletion:\n"
      . join('', map { "  $_ (deleted at $latest->{$_}{date})\n" } @shadowed)
      . "a merge commit probably restored them (git log --name-status does not\n"
      . "show merge diffs), so the derived stats and feed would treat live\n"
      . "translations as deleted. inspect the history before deriving again.\n"
      if @shadowed;

  my @unobserved = sort grep { !exists $latest->{$_} } keys %$current;
  die "these paths exist in the checkout but have no event in the history:\n"
      . join('', map { "  $_\n" } @unobserved)
      . "a merge commit probably created them while resolving a conflict (git log\n"
      . "--name-status does not show merge diffs), so the derived stats and feed\n"
      . "would omit live translations. inspect the history before deriving again.\n"
      if @unobserved;
}

# 現ツリーに旧構成のディレクトリが復活していたら止める。
#
# _normalize_historical_rel は履歴上の modules/... を現在の docs/modules/... に写す。
# 同じ名前のファイルが旧配置にも現行配置にもあると、両者のイベントは同じ path に
# 集まり、latest_events_by_path は「日時の新しい方」を採る。旧配置側が新しければ
# recent feed は旧配置の日時と author を現行 URL に結び付け、旧配置側が削除なら
# 現行のファイルが削除済みと誤判定される。旧配置は PodFile が取り込まないので
# 配信もされず、黙って通すと誤りだけが残る。
#
# current_paths が checkout 全体を拾っていた頃は、旧配置のファイルが
# 「イベントの無い現存 path」として上の検査に引っかかっていた。列挙を docs/ に
# 絞った分、その停止性をここで明示的に引き継ぐ。
sub _assert_no_legacy_layout {
  my ($class, $c) = @_;

  my @legacy;
  foreach my $repos (qw/translation/) {
      foreach my $dir (LEGACY_TOPLEVEL_DIRS) {
          my $base = File::Spec->catdir($c->assets_dir, $repos, $dir);
          next unless -d $base;
          push @legacy, map { "$dir/" . decode_path(File::Spec->abs2rel($_, $base)) }
              File::Find::Rule->file()->name(TRANSLATION_FILE_RE)->in($base);
      }
  }
  return unless @legacy;

  @legacy = sort @legacy;
  die "these translations use the pre-2023 layout in the checkout:\n"
      . join('', map { "  $_\n" } @legacy)
      . "the history normalizes such paths into docs/..., so their events would be\n"
      . "attributed to the current-layout file with the same name (or mark it as\n"
      . "deleted), while nothing under docs/ serves them. move them under docs/\n"
      . "before deriving again.\n";
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
