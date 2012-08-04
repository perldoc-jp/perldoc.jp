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
    my $year = $ARGV[0] or die "year is needed\n";
    my $date = Time::Piece->strptime("$year-01-01 00:00:00", '%Y-%m-%d %H:%M:%S');
    my $updates = PJP::M::Repository->recent_data($pjp, $date);
    create_file($updates, $year);
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

