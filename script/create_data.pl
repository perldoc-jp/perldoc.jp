#!/usr/bin/perl

# databuild の派生データ (recent feed / 年次統計 / docs.json / 目次) を
# 1 プロセスで生成する。翻訳イベントの導出は translation の git log 全走査で
# 高価なうえ、空チェックと shadowed-deletion 検査という不変条件を伴う。
# 生成物ごとに別プロセスで導出すると走査が重複し、検査の適用が生成物ごとに
# 非対称になるため、導出と検査をここで 1 回だけ行い、すべての生成物を同じ
# 検査済みイベント列から組み立てる。

use strict;
use warnings;

use utf8;
use Data::Dumper;
use List::Util qw/maxstr/;
use Time::Piece;
use JSON::XS ();
use XML::RSS;
use lib qw(./lib);
use PJP;
use PJP::Util qw/write_file_atomic/;
use Config::PL;
use Module::Find qw/useall/;

useall 'PJP::M';

local $Data::Dumper::Terse    = 1;
local $Data::Dumper::Sortkeys = 1;
# author 名や abstract など git・pod 由来の文字列が非 ASCII になっても読み手側の
# エンコーディング解釈に依存しないよう、\x{} 等でエスケープした純 ASCII で
# 出力する。ファイルに use utf8 ヘッダを書く方式は、読み手の config_do が
# do 時に @INC を cwd に限定するため「利用側プロセスが utf8.pm をロード済みか」
# に成否が依存してしまい使えない
local $Data::Dumper::Useqq    = 1;

# require されたとき (t/CreateData.t が生成の各段を直接呼ぶ) は実行しない
main() unless caller;

sub main {
    my $pjp = PJP->bootstrap;

    my $events = PJP::M::Repository->commit_events($pjp);
    # イベントが 1 件も無いのは translation checkout の異常。空の生成物を
    # 黙って作らず、ビルドを止めて気づけるようにする
    die "no translation events found" unless @$events;

    # 書き出す data/years.pl はデプロイ後に master へ自動コミットされて次回の
    # seed になる。イベント列が現ツリーと矛盾したまま導出すると誤りが恒久化
    # するため、全生成物の手前で 1 回だけ検査する
    PJP::M::Repository->assert_current_paths_observable($pjp, $events);

    mkdir './data' or die $! if not -d './data';

    create_recent($pjp, $events);
    create_year_data($events, $ARGV[0]);
    create_docs_json($pjp);
    create_index_data($pjp, $events);
}

sub create_recent {
    my ($pjp, $events) = @_;

    # path ごとの最新イベントを、現存する翻訳に限って集める (commit_events は
    # 削除・rename 済みの path のイベントも返す)
    my $current_paths = PJP::M::Repository->current_paths($pjp);
    my $latest_events = PJP::M::Repository->latest_events_by_path($events);
    my @live = grep { $current_paths->{$_->{path}} && !$_->{deleted} } values %$latest_events;
    die "no live translation found in the checkout" unless @live;

    # 掲載期間は現存翻訳の最新イベントから遡って 1 年。壁時計を基準にすると
    # 同じ translation からのビルドで結果が変わり、キャッシュされたレイヤの
    # 再利用で期限切れの項目が feed に残り続ける。全イベントの最大日時ではなく
    # 現存翻訳のそれを基準にするのは、古い翻訳の削除だけが最近の活動という
    # 期間に、窓が現存翻訳を 1 件も含まない位置まで進んでビルドが止まるため
    my $latest = maxstr(map { $_->{date} } @live);
    my $cutoff = (Time::Piece->strptime($latest, '%Y-%m-%d %H:%M:%S') - 365 * 86400)
        ->strftime('%Y-%m-%d %H:%M:%S');

    my @updates = grep { $_->{date} ge $cutoff } @live;
    die "no recent updates found in translation" unless @updates;

    # feed は新しい順 (同日時は path で締めて決定的にする)。件数の上限は
    # 旧実装の [0 .. $max] スライスと同じ (最大 $max + 1 件) を維持する
    my $max = 50;
    @updates = sort { $b->{date} cmp $a->{date} || $a->{path} cmp $b->{path} } @updates;
    @updates = @updates[0 .. $max] if $#updates > $max;

    write_data_pl('data/recent.pl', { recent => \@updates });
    create_rss(\@updates);
}

sub create_rss {
    my $updates = shift;

    mkdir 'static/rss' or die $! if not -d 'static/rss';

    # channel の日時は最新エントリのコミット日時から導出する (create_recent が
    # 新しい順に整列済み)。ファイルの mtime やビルド時刻に依らせないことで、
    # 同じ translation からのビルドは同じバイト列の feed になる
    my $latest = Time::Piece->strptime($updates->[0]{date}, '%Y-%m-%d %H:%M:%S');
    my $datetime = $latest->strftime("%a, %d %b %Y %H:%M:%S +0900");

    my $rss = XML::RSS->new(version => '2.0');
    $rss->channel(
        title          => 'perldoc.jp',
        link           => 'http://perldoc.jp/',
        language       => 'ja',
        description    => 'Perl の公式ドキュメント、モジュールを日本語翻訳したものを表示するサイトです。',
        copyright      => 'Japan Perl Association',
        pubDate        => $datetime,
        lastBuildDate  => $datetime,
        managingEditor => 'ktat@perlassociations.jp',
        webMaster      => 'ktat@perlassociations.jp',
        );

    foreach my $module (@{$updates}) {
        my $datetime = Time::Piece->strptime($module->{date}, '%Y-%m-%d %H:%M:%S');
        $rss->add_item(
            title       => $module->{name},
            link        => "http://perldoc.jp/" . $module->{path},
            description => ($module->{in} ? "$module->{in}の" : '') . "$module->{name}" . ($module->{version} ? "($module->{version})": '') . "が、$module->{author} により commit されました。",
            pubDate     => $datetime->strftime("%a, %d %b %Y %H:%M:%S +0900"),
            );
    }
    # XML::RSS の as_string は非 ASCII を数値文字参照に変換するので、返る文字列は
    # 常に ASCII の範囲に収まる。層は明示するが変換のためではなく、環境変数
    # (PERL_UNICODE) でハンドルに層が付いても出力バイト列が変わらないようにするため
    write_file_atomic('static/rss/recent.rss', sub {
        my $fh = shift;
        binmode $fh, ':raw';
        print {$fh} $rss->as_string;
    });
}

sub create_year_data {
    my ($events, $target_year) = @_;

    # 対象年は明示指定がなければ最新の翻訳イベントの前年。壁時計から導出
    # しないことで、同じ translation からのビルドは同じ生成物になる。
    # 当年ターゲットだと年をまたいだ瞬間に前年分が data/years.pl のシード
    # (最終コミット時点) で凍結され、シード更新から年末までの統計が
    # サイレントに欠落するため、前年以降を毎ビルド再導出する
    $target_year //= (maxstr(map { $_->{date} } @$events) =~ m{^(\d+)})[0] - 1;

    # data/years.pl は PJP::M::YearData::GIT_DERIVABLE_SINCE より前の統計の唯一の
    # 原本で、git 管理下にあるので常に存在する。読めない場合は config_do が croak し、中身が再利用に耐えるかは
    # build が検査する (結果はデプロイ成功後に master へ自動コミットされて
    # 次回ビルドの seed になるため、壊れたまま通すと復元できない)
    my $seed = scalar config_do('data/years.pl');
    PJP::M::YearData->assert_seed_is_complete($seed, $target_year);
    my $year = PJP::M::YearData->build($events, $seed, $target_year);

    write_data_pl('data/years.pl', $year);
}

# pod テーブルの package => path 対応表を static/docs.json に書き出す。
#
# 各 package の path は PJP::M::PodFile->get_latest で解決する。つまり
# docs.json が指す版は、アプリがその package のリクエストで表示する版と
# 常に一致する。SELECT の行順から後勝ちで決めると、結果がスキーマ
# (インデックスの走査順) に依存して古い版に化ける。
# キー順は canonical で固定し、同じ DB からは同じバイト列を生成する。
sub create_docs_json {
    my ($pjp) = @_;

    my %docs;
    my $packages = $pjp->dbh->selectcol_arrayref('SELECT DISTINCT package FROM pod');
    for my $package (@$packages) {
        my $path = PJP::M::PodFile->get_latest($package)
            or die "Cannot resolve the latest path for package: $package";
        $docs{$package} = $path;
    }

    # ->utf8 で encode 側にバイト列を作らせる。付けないと非 ASCII の package が
    # 内部表現のまま raw ハンドルへ出て、latin-1 のバイト列や wide character 警告になる
    write_file_atomic('static/docs.json', sub {
        my $fh = shift;
        binmode $fh, ':raw';
        print {$fh} JSON::XS->new->canonical->utf8->encode(\%docs);
    });
}

# /index/module と /index/article の目次データを data/ に書き出す。
# 目次の事前生成は #55/#56 で「cron での index ファイル生成と相性が悪い」
# ため実行時キャッシュに変更されたが、データ更新がイメージ再ビルド
# (databuild) に一本化されたことで前提が変わったため、ビルド時生成に戻す。
sub create_index_data {
    my ($pjp, $events) = @_;

    # abstract を含む大きな構造なので、目次データだけ従来どおり Indent=1 で
    # 出力する (バイト列を既存の生成物から変えない)
    my @modules = PJP::M::Index::Module->generate($pjp);
    die "PJP::M::Index::Module->generate returned no entries" unless @modules;
    write_data_pl('data/index-module.pl', { index => \@modules }, indent => 1);

    my @articles = PJP::M::Index::Article->generate($pjp);
    die "PJP::M::Index::Article->generate returned no entries" unless @articles;
    write_data_pl('data/index-article.pl', { index => [sort_by_updated_at($events, \@articles)] },
                  indent => 1);
}

# その他の翻訳の一覧を「更新が新しい順」に並べる。
#
# 順序の入力は翻訳イベントの日付にする。ファイルの mtime は、生成が cron から
# イメージビルドに移って translation を毎回 clone するようになった時点で
# 「更新が新しい順」を表さなくなった (全ファイルが checkout 時刻に潰れ、
# 同時刻どうしは readdir 順 = 環境依存)。
#
# distvname は articles/ 以下の相対 path なので、docs/ を足すと commit_events が
# 返す path 形式になる。イベントの無い path (履歴が翻訳文書の構成に合わない等) は
# 日付なしとして末尾に送り、同順は distvname で締めて全順序にする。
sub sort_by_updated_at {
    my ($events, $articles) = @_;

    my $latest_events = PJP::M::Repository->latest_events_by_path($events);

    my @keyed = map {
        my $event = $latest_events->{"docs/articles/$_->{distvname}"};
        [ $event ? $event->{date} : '', $_ ]
    } @$articles;

    # イベントの無い path は日付なし (末尾送り) が正しいが、全滅は結合キーの
    # 組み立てがイベントの path 形式からドリフトした兆候。放置すると一覧が
    # 黙って distvname 逆順に退化する (エラーは出ず、リンク数のテストも通る)
    die "no article matched any translation event; the join key drifted from the event path format?"
        unless grep { $_->[0] ne '' } @keyed;

    return map  { $_->[1] }
           sort { $b->[0] cmp $a->[0] || $a->[1]{distvname} cmp $b->[1]{distvname} }
           @keyed;
}

# 先頭の + は do がブロックと誤解釈しないための明示。
# indent は生成物ごとに違う (目次データだけ従来の Indent=1 を保つ) ため引数で受ける
sub write_data_pl {
    my ($path, $data, %opts) = @_;
    local $Data::Dumper::Indent = $opts{indent} if defined $opts{indent};
    write_file_atomic($path, sub { print {$_[0]} '+', Dumper($data) });
}
