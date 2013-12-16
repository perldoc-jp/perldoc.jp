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

my %IGNORE_FILES = (
    'modules/CGI-FastTemplate-1.09/README' => 1,
    );

main();

sub main {
    my $pjp  = PJP->bootstrap;
    my $year = $ARGV[0] or die "year is needed\n";
    my $date = Time::Piece->strptime("$year-01-01 00:00:00", '%Y-%m-%d %H:%M:%S');
    my $updates = PJP::M::Repository->recent_data($pjp, $date);
    create_file($updates, $year);
    update_pod_update_time($pjp, $updates);
}

sub update_pod_update_time {
    my ($pjp, $updates) = @_;
    foreach my $update (@$updates) {
	next if $update->{path} =~ m{\.zip$} or $update->{path} =~ m{\.pot?$} or $update->{path} =~m{pod\.org$};

	$update->{path} =~s{^docs/}{};
	$update->{path} =~s{^modules/docs/}{};
	$update->{path} =~s{^core/}{perl/};
	$update->{path} =~s{^modules/(\w+)\.pm(-[\d.]+)}{modules/$1$2};

	if (my $data = PJP::M::PodFile->retrieve($update->{path})) {
	    $data->{update_time} = Time::Piece->strptime($update->{date}, '%Y-%m-%d %H:%M:%S')->epoch;
	    $pjp->dbh_master->replace(pod => $data);
	    $pjp->dbh_master->update
		( heavy_diff => {origin => $data->{path}, time => {'<' => $data->{update_time}}} , {is_cached => 0});
	    $pjp->dbh_master->update
		( heavy_diff => {target => $data->{path}, time => {'<' => $data->{update_time}}} , {is_cached => 0});
	} else {
	    next if $IGNORE_FILES{$update->{path}};
	    warn "the path cannot be found in DB: " . $update->{path};
	}
    }
}

sub create_file {
    my ($updates, $target_year) = @_;
    my $year = do("data/years.pl");
    if ($year) {
        push @$updates, sort { $b->{date} cmp $a->{date} }map { @{$year->{$_}->{modules}} } grep {$_ < $target_year} keys %$year;
    } else {
        $year = {};
    }
    my %first;
    my %module;

    foreach my $module (reverse @$updates) {
        if ($module->{date} =~m{^(\d+)}) {
            my $y = $1;
            if (not $first{$y}++) {
                $year->{$y}->{modules}          = [];
                $year->{$y}->{commit_count}     = {};
                if ($y >= $target_year) {
                    $year->{$y}->{commit_count_all} = {};
                }
            }
            my $n;
            if ($module->{in} eq 'perl') {
                $n = $module{perl}->{$module->{name}}->{$module->{version}}++;
            } else {
                $n = $module{$module->{in}}->{$module->{version}}++;
            }
            if (not $n) {
                push @{$year->{$y}->{modules}}, $module;
                $year->{$y}->{commit_count}->{$module->{author}}++;
                if ($y >= $target_year) {
                    $year->{$y}->{commit_count_all}->{$module->{author}}++;
                }
            } else {
                if ($y >= $target_year) {
                    $year->{$y}->{commit_count_all}->{$module->{author}}++;
                }
            }
        }
    }

    foreach my $y (keys %$year) {
        my %tmp;
        if (ref $year->{$y}->{commit_count} eq 'HASH') {
            $year->{$y}->{commit_count} =
                [
                 map {
                     [ $_, $year->{$y}->{commit_count_all}->{$_}, $year->{$y}->{commit_count}->{$_} ]
                 }
                 sort {
                     ($tmp{$b} ||= $year->{$y}->{commit_count_all}->{$b})
                         <=>
                     ($tmp{$a} ||= $year->{$y}->{commit_count_all}->{$a})
                 } keys %{$year->{$y}->{commit_count_all}}
                ];
        }
    }

    mkdir './data' or die $! if not -d './data';

    open my $fh, '>', "data/years.pl.new" or die $!;
    print $fh Dumper($year);
    close $fh;
    rename "data/years.pl.new", "data/years.pl";
}

