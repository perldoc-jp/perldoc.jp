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
use Time::Piece;

useall 'PJP::M';

local $Data::Dumper::Terse = 1;

main();

sub main {
    my $pjp  = PJP->bootstrap;
    my $date = Time::Piece->new - 365 * 86400;;
    my $updates = PJP::M::Repository->recent_data($pjp, $date);
    my $max = 50;
    if ($#{$updates} > $max) {
        $updates = [@{$updates}[0 .. $max]];
    }
    if (create_file($updates)) {
        create_rss($updates);
    }
}

sub create_file {
    my $updates = shift;

    mkdir './data' or die $! if not -d './data';

    open my $fh, '>', "data/recent.pl.new" or die $!;
    print $fh Dumper($updates);
    close $fh;
    if (! -e "data/recent.pl" or qx{diff data/recent.pl data/recent.pl.new}) {
        rename "data/recent.pl.new", "data/recent.pl";
        return 1;
    } else {
        unlink "data/recent.pl.new";
        return 0;
    }
}

sub create_rss {
    my $updates = shift;

    mkdir 'static/rss' or die $! if not -d 'static/rss';

    my $mtime = (stat "data/recent.pl")[9];
    my $datetime = (localtime $mtime)->strftime("%a, %d %b %Y %H:%M:%S +0900");

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
