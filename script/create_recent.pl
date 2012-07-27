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
    my $updates = create_recent_data();
    if (create_file($updates)) {
        create_rss($updates);
    }
}

sub create_recent_data {
    my $pjp        = PJP->bootstrap;
    my $config     = $pjp->config;
    my $mode_name  = $pjp->mode_name || 'development';

    my $assets_dir = $config->{'assets_dir'} || die "no assets_dir setting in config/" . $mode_name . '.pl';
    my $code_dir   = $config->{'code_dir'}   || die "no code_dir setting in config/"   . $mode_name . '.pl';

    my $date = Time::Piece->new;
    $date -= 365 * 86400;

    my $cvs = qx{cd ${assets_dir}perldoc.jp/docs/; cvs history -x AMR -l -a -D '$date'|sort};
    my @updates;

    1 while $cvs =~ s{^. (\d{4}-\d{2}-\d{2}) \d{2}:\d{2} \+0000 ([^ ]+) +[\d\.]+ +([^ ]+) +([^ ]+)}{
        push @updates, {
            date   => $1,
            author => $2,
            path   => "$4/$3",
            name   => file2name("$4/$3"),
        }
    }em;

    foreach my $repos (qw/Moose-Doc-JA MooseX-Getopt-Doc-JA/) {
        foreach my $file (File::Find::Rule->file()->name('*.pod')->in("$assets_dir$repos")) {
            my $git = qx{cd $assets_dir/$repos/; git log -1 --date=iso --pretty='%cd -- %an' --since='$date'} or next;
            my ($date, $author) = $git =~m{^(\d{4}-\d{2}-\d{2}) \d{2}:\d{2}:\d{2} \+\d{4} -- (.+)$} or die $git;
            $file =~s{^.+?assets/}{};
            $file =~s{^\Q$repos/\E}{};
            push @updates, {date => $date, author => $author, path => 'docs/modules/' . $file, name => file2name($file)};
        }
    }
    return \@updates;
}

sub create_file {
    my $updates = shift;

    mkdir './data' or die $! if not -d './data';

    open my $fh, '>', "data/recent.pl.new" or die $!;
    my %tmp;
    print $fh Dumper([( sort {($tmp{$b} ||= $b->{date}) cmp ($tmp{$a} ||= $a->{date})} @$updates )[0 .. 50]]);
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

    foreach my $module (@{$updates}[0 .. 50]) {
        my $datetime = Time::Piece->strptime($module->{date}, '%Y-%m-%d %H:%M:%S');
        $rss->add_item(
            title       => $module->{name},
            link        => "http://perldoc.jp/" . $module->{path},
            description => "$module->{name} が、$module->{author} により commit されました。",
            pubDate     => $datetime->strftime("%a, %d %b %Y %H:%M:%S +0900"),
            );
    }
    open my $fh, '>', 'static/rss/recent.rss' or die $!;
    print $fh $rss->as_string;
    close $fh;
}

sub file2name {
    my $name = shift;
    $name =~ s{^docs/modules/[^/]+/lib/}{};
    $name =~ s{^docs/perl/[^/]+/}{};
    $name =~ s{\.pod$}{};
    $name =~ s{/+}{/}g;
    $name =~ s{/}{::}g;
    return $name;
}
