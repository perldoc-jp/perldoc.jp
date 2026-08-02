use v5.38;
use utf8;
use Test2::V0;

use PJP::M::YearData;

# data/years.pl の modules エントリと同じ形
sub entry {
    my (%args) = @_;
    return {
        date    => $args{date},
        author  => $args{author}  // 'tester',
        path    => $args{path},
        name    => $args{name}    // 'Foo',
        in      => $args{in}      // 'Foo',
        version => $args{version} // '1.00',
    };
}

# seed の 1 年分。commit_count は ARRAY、commit_count_all は HASH で持つ
# (実際の data/years.pl と同じ形)
sub seed_year {
    my ($modules, $counts) = @_;
    return {
        modules          => $modules,
        commit_count     => [ map { [ $_, $counts->{$_}, $counts->{$_} ] } sort keys %$counts ],
        commit_count_all => {%$counts},
    };
}

sub paths_of { [ sort map { $_->{path} } @{ $_[0]{modules} // [] } ] }

subtest '対象年より前は seed から復元される' => sub {
    my $old = entry(date => '2010-05-01 00:00:00', path => 'docs/modules/Old-1.00/Old.pod', in => 'Old');
    my $seed = { 2010 => seed_year([$old], { alice => 1 }) };

    my $year = PJP::M::YearData->build([], $seed, 2025, {});
    is paths_of($year->{2010}), ['docs/modules/Old-1.00/Old.pod'],
        '2010 のエントリが git 由来なしでも残る';
};

subtest '削除された翻訳の seed が対象年でも保持される' => sub {
    # 2025 に翻訳された 2 件のうち、Bar が 2026 に削除された状況。
    # 再導出 ($updates) には Foo しか出てこない
    my $foo = entry(date => '2025-06-01 00:00:00', path => 'docs/modules/Foo-1.00/Foo.pod', in => 'Foo');
    my $bar = entry(date => '2025-07-01 00:00:00', path => 'docs/modules/Bar-1.00/Bar.pod', in => 'Bar', author => 'bob');
    my $seed = { 2025 => seed_year([$foo, $bar], { tester => 1, bob => 1 }) };

    my $current = { 'docs/modules/Foo-1.00/Foo.pod' => 1 };  # Bar は現ツリーに無い
    my $year = PJP::M::YearData->build([ entry(%$foo) ], $seed, 2025, $current);

    is paths_of($year->{2025}), [
        'docs/modules/Bar-1.00/Bar.pod',
        'docs/modules/Foo-1.00/Foo.pod',
    ], '削除された Bar も 2025 に残る';

    my %count = map { $_->[0] => $_->[2] } @{ $year->{2025}{commit_count} };
    is $count{bob}, 1, '削除された翻訳の author のコミット数も残る';
};

subtest '現ツリーに在る path は seed と再導出で二重にならない' => sub {
    my $foo = entry(date => '2025-06-01 00:00:00', path => 'docs/modules/Foo-1.00/Foo.pod', in => 'Foo');
    my $seed = { 2025 => seed_year([$foo], { tester => 1 }) };

    my $current = { 'docs/modules/Foo-1.00/Foo.pod' => 1 };
    my $year = PJP::M::YearData->build([ entry(%$foo) ], $seed, 2025, $current);

    is paths_of($year->{2025}), ['docs/modules/Foo-1.00/Foo.pod'], '1 件のまま';
    my %count = map { $_->[0] => $_->[1] } @{ $year->{2025}{commit_count} };
    is $count{tester}, 1, 'commit_count_all も二重加算されない';
};

subtest '保持した seed が古い年の実績を横取りしない' => sub {
    # 同じ (in, version) が 2010 と 2025 の両方に出る (dist 内の別 pod)。
    # 「最初に現れた年に計上する」規則は updates 全体のソートに依存しており、
    # 保持した seed をブロックとして継ぎ足すだけだと reverse で先頭に来て
    # 2010 の実績を奪ってしまう
    my $old = entry(date => '2010-05-01 00:00:00', path => 'docs/modules/Foo-1.00/Foo.pod',
                    in => 'Foo', version => '1.00', author => 'alice');
    my $new = entry(date => '2025-05-01 00:00:00', path => 'docs/modules/Foo-1.00/Bar.pod',
                    in => 'Foo', version => '1.00', author => 'bob', name => 'Foo::Bar');
    my $seed = {
        2010 => seed_year([$old], { alice => 1 }),
        2025 => seed_year([$new], { bob   => 1 }),
    };

    # 両方とも現ツリーには無い (2025 側は保持の対象になる)
    my $year = PJP::M::YearData->build([], $seed, 2025, {});

    is paths_of($year->{2010}), ['docs/modules/Foo-1.00/Foo.pod'],
        '2010 が modules を保持する';
    is paths_of($year->{2025}), [], '2025 は重複として modules には積まれない';
    my %count = map { $_->[0] => $_->[1] } @{ $year->{2025}{commit_count} };
    is $count{bob}, 1, '2025 側は commit_count_all にだけ計上される';
};

subtest 'seed が無くても組み立てられる (初回ビルド)' => sub {
    my $foo = entry(date => '2025-06-01 00:00:00', path => 'docs/modules/Foo-1.00/Foo.pod');
    my $year = PJP::M::YearData->build([$foo], undef, 2025, {});
    is paths_of($year->{2025}), ['docs/modules/Foo-1.00/Foo.pod'], '再導出分だけで作れる';
};

subtest '同じ入力なら結果が変わらない (冪等)' => sub {
    my $foo = entry(date => '2025-06-01 00:00:00', path => 'docs/modules/Foo-1.00/Foo.pod');
    my $old = entry(date => '2010-05-01 00:00:00', path => 'docs/modules/Old-1.00/Old.pod', in => 'Old');
    my $current = { 'docs/modules/Foo-1.00/Foo.pod' => 1 };

    my $first  = PJP::M::YearData->build([ entry(%$foo) ], undef, 2025, $current);
    $first->{2010} = seed_year([$old], { alice => 1 });
    my $second = PJP::M::YearData->build([ entry(%$foo) ], $first, 2025, $current);

    is paths_of($second->{2025}), paths_of($first->{2025}), '2025 が変わらない';
    is paths_of($second->{2010}), ['docs/modules/Old-1.00/Old.pod'], '2010 も保たれる';
};

done_testing;
