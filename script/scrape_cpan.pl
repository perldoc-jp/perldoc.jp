#!/usr/bin/perl

use lib qw(../lib);
use strict;
use warnings;
use Web::Scraper;
use URI;
use PJP;
use PJP::M::PodFile;
use LWP::UserAgent::WithCache;
use Data::Dumper;

local $Data::Dumper::Terse  = 1;

main();

sub main {
    my $pjp = PJP->bootstrap;
    my ($category_names, $categories) = scrape_cpan();
    my %tt_structure;
    foreach my $category (keys %$categories) {
        $tt_structure{$category} = {in_category => [], others => []};
        my @in_category = @{$categories->{$category}->{modules}} ?
            PJP::M::PodFile->search_by_packages($categories->{$category}->{modules}) : ();
        my @others      = @{$categories->{$category}->{sub}} ?
            PJP::M::PodFile->search_by_packages_like([map {"$_%"} @{$categories->{$category}->{sub}}]) : ();
        my %tmp;
        $tt_structure{$category}{in_category} = [grep {not $tmp{$_->{package}}++} grep $_, @in_category];
        $tt_structure{$category}{others}      = [grep {not $tmp{$_->{package}}++} grep $_, @others];
    }
    mkdir './data' or die $! if not -d './data';
    open my $fh, '>', "data/category_data.pl.new" or die $!;
    print $fh '+{category_names => ';
    print $fh Dumper($category_names);
    print $fh ', category_modules => ';
    print $fh Dumper(\%tt_structure);
    print $fh '}';
    close $fh;
    rename "data/category_data.pl.new", "data/category_data.pl"
}

sub scrape_cpan {
    my $ua = LWP::UserAgent::WithCache->new(
                                            'namespace'          => 'perldoc.jp',
                                            'default_expires_in' => 3600,
                                            'cache_root'         => '/tmp/perldocjp',
                                           );
    my $s = scraper {
        process "td a", "category_links[]" => '@href';
        process "td a", "category_names[]" => 'TEXT';
    };
    my $r = $s->scrape($ua->get('http://search.cpan.org/')->content);

    my $module_scraper = scraper {
        process "tr.r td:first-child a", "module_names[]" => 'TEXT';
        process "center.categories a", 'module_categories[]' => 'TEXT';
    };

    my %categories;
    my @category_names = @{$r->{category_names}};
    for (my $i = 0; $i < @category_names; $i++) {
        my $name = $category_names[$i];
        my $link = $r->{category_links}->[$i];
        $categories{$name} = {link => $link, sub => [], modules => []};
        my $r = $module_scraper->scrape($ua->get("http://search.cpan.org$link")->content);
        foreach my $mod_cate (@{$r->{module_categories}}) {
            push @{$categories{$name}->{sub}}, $mod_cate;
        }
        foreach my $mod_name (@{$r->{module_names}}) {
            push @{$categories{$name}->{modules}}, $mod_name;
        }
    }
    return \@category_names, \%categories;
}

