#!/usr/bin/perl

use strict;
use warnings;

use utf8;
use Data::Dumper;
use Time::Piece;
use lib qw(./lib);
use PJP;
use Module::Find qw/useall/;
use XML::RSS;

useall 'PJP::M';

local $Data::Dumper::Terse    = 1;
local $Data::Dumper::Sortkeys = 1;
# author 名など git 由来の文字列が非 ASCII になっても読み手側の
# エンコーディング解釈に依存しないよう、index データ
# (create_index_data.pl) と同じく純 ASCII で出力する
local $Data::Dumper::Useqq    = 1;

main();

sub main {
    my $pjp    = PJP->bootstrap;
    my $events = PJP::M::Repository->commit_events($pjp);
    # イベントが 1 件も無いのは translation checkout の異常。
    # 空の feed を黙って作らず、ビルドを止めて気づけるようにする
    die "no translation events found" unless @$events;

    # 掲載期間は最新の翻訳イベントから遡って 1 年。壁時計を基準にすると
    # 同じ translation からのビルドで結果が変わり、キャッシュされたレイヤの
    # 再利用で期限切れの項目が feed に残り続ける
    my $latest = Time::Piece->strptime($events->[0]{date}, '%Y-%m-%d %H:%M:%S');
    my $cutoff = ($latest - 365 * 86400)->strftime('%Y-%m-%d %H:%M:%S');

    # path ごとの最新イベントを、現存する翻訳に限って新しい順に集める
    # (commit_events は削除・rename 済みの path のイベントも返す)
    my $current_paths = PJP::M::Repository->current_paths($pjp);
    my $max = 50;
    my (%seen, @updates);
    foreach my $event (@$events) {
        last if $event->{date} lt $cutoff;
        last if @updates > $max;
        next if $seen{$event->{path}}++;
        next unless $current_paths->{$event->{path}};
        push @updates, $event;
    }
    die "no recent updates found in translation" unless @updates;

    create_file(\@updates);
    create_rss(\@updates);
}

sub create_file {
    my $updates = shift;

    mkdir './data' or die $! if not -d './data';

    open my $fh, '>', "data/recent.pl" or die $!;
    # Config::PL (config_do) で読めるように HashRef で包む。
    # 先頭の + は do がブロックと誤解釈しないための明示
    print $fh '+', Dumper({ recent => $updates });
    close $fh;
}

sub create_rss {
    my $updates = shift;

    mkdir 'static/rss' or die $! if not -d 'static/rss';

    # channel の日時は最新エントリのコミット日時から導出する (commit_events は
    # 日時の降順ソート済み)。ファイルの mtime やビルド時刻に依らせないことで、
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
    open my $fh, '>', 'static/rss/recent.rss' or die $!;
    print $fh $rss->as_string;
    close $fh;
}
