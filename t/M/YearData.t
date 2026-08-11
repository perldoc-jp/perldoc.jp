use v5.38;
use utf8;
use Test2::V0;

use Storable qw/dclone/;
use PJP::M::YearData;

# PJP::M::Repository->commit_events のイベントと同じ形
sub entry {
    my (%args) = @_;
    return {
        date    => $args{date},
        author  => $args{author}  // 'tester',
        path    => $args{path},
        name    => $args{name}    // 'Foo',
        in      => $args{in}      // 'Foo',
        version => $args{version} // '1.00',
        ($args{deleted} ? (deleted => 1) : ()),
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

    my $year = PJP::M::YearData->build([], $seed, 2025);
    is paths_of($year->{2010}), ['docs/modules/Old-1.00/Old.pod'],
        '2010 のエントリが git 由来なしでも残る';
};

subtest '削除された翻訳の実績がイベントから再導出される' => sub {
    # 2025 に翻訳された Bar が 2026 に削除された状況。commit_events は
    # 削除済み path のイベントも返すので、seed に頼らず 2025 の実績が残る
    my @events = (
        entry(date => '2026-03-01 00:00:00', path => 'docs/modules/Bar-1.00/Bar.pod', in => 'Bar',
              author => 'remover', deleted => 1),
        entry(date => '2025-07-01 00:00:00', path => 'docs/modules/Bar-1.00/Bar.pod', in => 'Bar', author => 'bob'),
        entry(date => '2025-06-01 00:00:00', path => 'docs/modules/Foo-1.00/Foo.pod', in => 'Foo'),
    );

    my $year = PJP::M::YearData->build(\@events, undef, 2025);

    is paths_of($year->{2025}), [
        'docs/modules/Bar-1.00/Bar.pod',
        'docs/modules/Foo-1.00/Foo.pod',
    ], '削除された Bar も 2025 に残る';

    my %count = map { $_->[0] => $_->[2] } @{ $year->{2025}{commit_count} };
    is $count{bob}, 1, '削除された翻訳の author のコミット数も残る';

    is $year->{2026}, undef, '削除しか起きていない 2026 は現れない';
};

subtest '既存翻訳への更新だけの年も削除後に再導出できる' => sub {
    # 2010 年からある Foo を bob が 2025 年に更新し、2026 年に削除された状況。
    # modules (初出) は 2010 のままなので、更新イベントそのものが観測できないと
    # 2025 の bob の実績を復元できない
    my $first = entry(date => '2010-05-01 00:00:00', path => 'docs/modules/Foo-1.00/Foo.pod', author => 'alice');
    my @events = (
        entry(date => '2026-03-01 00:00:00', path => 'docs/modules/Foo-1.00/Foo.pod', author => 'remover', deleted => 1),
        entry(date => '2025-07-01 00:00:00', path => 'docs/modules/Foo-1.00/Foo.pod', author => 'bob'),
    );
    my $seed = { 2010 => seed_year([$first], { alice => 1 }) };

    my $year = PJP::M::YearData->build(\@events, $seed, 2025);

    my %count = map { $_->[0] => $_->[1] } @{ $year->{2025}{commit_count} };
    is $count{bob}, 1, '削除前年の更新が commit_count_all に残る';
    is paths_of($year->{2025}), [], '初出は 2010 なので 2025 の modules には積まれない';
    is paths_of($year->{2010}), ['docs/modules/Foo-1.00/Foo.pod'], '2010 の初出は seed から保たれる';
};

subtest '年内最終イベントが削除なら、その年には数えない' => sub {
    # 追加と削除が同じ年に起きたら、年末時点にファイルは無い
    # (旧 VPS の年末凍結と同じ見え方)
    my @events = (
        entry(date => '2025-07-01 00:00:00', path => 'docs/modules/Tmp-1.00/Tmp.pod', in => 'Tmp', deleted => 1),
        entry(date => '2025-03-01 00:00:00', path => 'docs/modules/Tmp-1.00/Tmp.pod', in => 'Tmp'),
        entry(date => '2025-06-01 00:00:00', path => 'docs/modules/Foo-1.00/Foo.pod', in => 'Foo'),
    );
    my $year = PJP::M::YearData->build(\@events, undef, 2025);
    is paths_of($year->{2025}), ['docs/modules/Foo-1.00/Foo.pod'],
        '年内に消えた翻訳は載らない';
};

subtest '同じ path の同年イベントは年内最終だけが数えられる' => sub {
    my @events = (
        entry(date => '2025-07-01 00:00:00', path => 'docs/modules/Foo-1.00/Foo.pod', author => 'bob'),
        entry(date => '2025-03-01 00:00:00', path => 'docs/modules/Foo-1.00/Foo.pod', author => 'alice'),
    );
    my $year = PJP::M::YearData->build(\@events, undef, 2025);
    my %count = map { $_->[0] => $_->[1] } @{ $year->{2025}{commit_count} };
    is \%count, { bob => 1 }, '年内最終コミットの author だけが数えられる';
};

subtest '同秒の追加と削除は配列の先頭側 (新しい方) が勝つ' => sub {
    # commit_events はイベントを git のコミット順 (新しい順) で返し、
    # 年内最終の判定は (年, path) の初出採用なので、配列で先に現れた方が
    # 最終イベントとして扱われる
    my $add = entry(date => '2025-06-01 12:00:00', path => 'docs/modules/Tmp-1.00/Tmp.pod', in => 'Tmp');
    my $del = entry(date => '2025-06-01 12:00:00', path => 'docs/modules/Tmp-1.00/Tmp.pod', in => 'Tmp', deleted => 1);

    is PJP::M::YearData->build([$del, $add], undef, 2025)->{2025}, undef,
        '先頭が削除なら年に現れない';
    is paths_of(PJP::M::YearData->build([$add, $del], undef, 2025)->{2025}),
        ['docs/modules/Tmp-1.00/Tmp.pod'],
        '先頭が追加なら年に現れる';
};

subtest '対象年以降の seed は使われない (削除だけの年が seed から復活しない)' => sub {
    # 前回ビルドの seed に 2026 のブロックが残った状態で、2026 年のイベントが
    # 「追加 → 削除」だけになった状況 (年明けに追加された翻訳がすぐ消された等)。
    # 年内最終が削除なので 2026 は現れてはならない。seed 側のブロックが
    # 生き残ると、自動コミットで書き戻されて以後のビルドでも残り続ける
    my $old   = entry(date => '2010-05-01 00:00:00', path => 'docs/modules/Old-1.00/Old.pod', in => 'Old');
    my $stale = entry(date => '2026-01-05 00:00:00', path => 'docs/modules/Tmp-1.00/Tmp.pod', in => 'Tmp', author => 'bob');
    my $seed  = {
        2010 => seed_year([$old],   { alice => 1 }),
        2026 => seed_year([$stale], { bob   => 1 }),
    };
    my @events = (
        entry(date => '2026-01-07 00:00:00', path => 'docs/modules/Tmp-1.00/Tmp.pod', in => 'Tmp',
              author => 'remover', deleted => 1),
        entry(date => '2026-01-05 00:00:00', path => 'docs/modules/Tmp-1.00/Tmp.pod', in => 'Tmp', author => 'bob'),
    );

    my $year = PJP::M::YearData->build(\@events, $seed, 2025);

    is $year->{2026}, undef, '削除しか残っていない 2026 は seed があっても現れない';
    is paths_of($year->{2010}), ['docs/modules/Old-1.00/Old.pod'], '対象年より前の seed は保たれる';
};

subtest '再導出できない年を対象にしたらビルドを止める' => sub {
    # 2011 年より前の統計は git 履歴から再現できない凍結データ。対象年にすると
    # seed の保護 (対象年より前だけ取り込む) から外れ、不完全な導出結果で
    # 黙って上書きされる。docs/cloud-run.md の回復手順は対象年を手動指定する
    # ので、誤指定はここで止める
    my $foo = entry(date => '2025-06-01 00:00:00', path => 'docs/modules/Foo-1.00/Foo.pod');
    like dies { PJP::M::YearData->build([$foo], undef, 2002) },
        qr/predates git-derivable history/, '2011 年より前の対象年で die する';
    like dies { PJP::M::YearData->build([$foo], undef, '20xx') },
        qr/must be a 4-digit year/, '年でない対象年で die する';
    like dies { PJP::M::YearData->build([$foo], undef, undef) },
        qr/must be a 4-digit year/, '対象年なしで die する';
};

subtest '対象年より前の年が縮んだら die する' => sub {
    # seed 由来の年も「最初に現れた年に計上する」再構築ループを通るため、
    # キーの解釈の誤り等で seed 済みのエントリが食われる余地がある。結果は
    # 自動コミットで次回ビルドの seed になるので、失われたら返す前に止める
    my $a = entry(date => '2010-05-01 00:00:00', path => 'docs/modules/Foo-1.00/Foo.pod',
                  in => 'Foo', version => '1.00');
    my $dup = entry(date => '2012-05-01 00:00:00', path => 'docs/modules/Foo-1.00/Bar.pod',
                    in => 'Foo', version => '1.00', name => 'Bar');
    my $seed = {
        2010 => seed_year([$a],   { alice => 1 }),
        2012 => seed_year([$dup], { bob   => 1 }),
    };
    like dies { PJP::M::YearData->build([], $seed, 2025) },
        qr/year 2012 lost modules/, '重複排除に食われた年で die する';
};

subtest 'build が seed を変更しない' => sub {
    # build の結果は seed とは別の構造として返る。seed を書き換えると、
    # build 自身の完全性検査 (seed と結果の突き合わせ) が自明に通ってしまい
    # 成立しない
    my $old = entry(date => '2010-05-01 00:00:00', path => 'docs/modules/Old-1.00/Old.pod', in => 'Old');
    my $cur = entry(date => '2026-02-01 00:00:00', path => 'docs/modules/New-1.00/New.pod', in => 'New');
    my $seed = {
        2010 => seed_year([$old], { alice => 1 }),
        2026 => seed_year([$cur], { bob   => 1 }),
    };
    my $before = dclone($seed);

    PJP::M::YearData->build([$cur], $seed, 2025);

    is $seed, $before, 'seed は呼び出し後も元のまま';
};

subtest '再導出が古い年の実績を横取りしない' => sub {
    # 同じ (in, version) が 2010 (seed) と 2025 (イベント) の両方に出る
    # (dist 内の別 pod)。「最初に現れた年に計上する」規則が seed 注入後の
    # 並べ替えで保たれること
    my $old = entry(date => '2010-05-01 00:00:00', path => 'docs/modules/Foo-1.00/Foo.pod',
                    in => 'Foo', version => '1.00', author => 'alice');
    my $new = entry(date => '2025-05-01 00:00:00', path => 'docs/modules/Foo-1.00/Bar.pod',
                    in => 'Foo', version => '1.00', author => 'bob', name => 'Foo::Bar');
    my $seed = { 2010 => seed_year([$old], { alice => 1 }) };

    my $year = PJP::M::YearData->build([$new], $seed, 2025);

    is paths_of($year->{2010}), ['docs/modules/Foo-1.00/Foo.pod'],
        '2010 が modules を保持する';
    is paths_of($year->{2025}), [], '2025 は重複として modules には積まれない';
    my %count = map { $_->[0] => $_->[1] } @{ $year->{2025}{commit_count} };
    is $count{bob}, 1, '2025 側は commit_count_all にだけ計上される';
};

subtest '旧規則の in を持つ seed と新規則のイベントが二重計上されない' => sub {
    # モジュール名の導出は「先頭のハイフン 1 個だけ ::」の時代があり、seed には
    # Class::Data-Inheritable のような旧規則の in が凍結されている。現行規則は
    # 全ハイフンを :: にするため、同じ dist の同じ版のイベントが文字列としては
    # 一致しない。重複排除が表記の違いを越えて効かないと、seed 済みの版が
    # 対象年に再掲載され、翻訳者の commit_count が水増しされる
    my $old = entry(date => '2010-05-01 00:00:00', path => 'docs/modules/Class-Data-Inheritable-0.06/Inheritable.pod',
                    in => 'Class::Data-Inheritable', version => '0.06', author => 'alice');
    my $new = entry(date => '2025-05-01 00:00:00', path => 'docs/modules/Class-Data-Inheritable-0.06/Inheritable.pod',
                    in => 'Class::Data::Inheritable', version => '0.06', author => 'bob');
    my $seed = { 2010 => seed_year([$old], { alice => 1 }) };

    my $year = PJP::M::YearData->build([$new], $seed, 2025);

    is paths_of($year->{2010}), ['docs/modules/Class-Data-Inheritable-0.06/Inheritable.pod'],
        '2010 の初出は seed のまま';
    is paths_of($year->{2025}), [], '同じ dist の同じ版は 2025 に再掲載されない';
    my %count = map { $_->[0] => $_->[2] } @{ $year->{2025}{commit_count} };
    is $count{bob}, undef, '初出扱いの commit_count には計上されない';
};

subtest 'seed が無くても組み立てられる (初回ビルド)' => sub {
    my $foo = entry(date => '2025-06-01 00:00:00', path => 'docs/modules/Foo-1.00/Foo.pod');
    my $year = PJP::M::YearData->build([$foo], undef, 2025);
    is paths_of($year->{2025}), ['docs/modules/Foo-1.00/Foo.pod'], '再導出分だけで作れる';
};

subtest '入力を変更しない・同じ入力なら結果が変わらない' => sub {
    # build が引数の配列を書き換えると、呼び出し元が同じイベント列を
    # 別の用途に再利用したときに壊れる
    my $events = [
        entry(date => '2025-06-01 00:00:00', path => 'docs/modules/Foo-1.00/Foo.pod'),
        entry(date => '2025-03-01 00:00:00', path => 'docs/modules/Old-1.00/Old.pod', in => 'Old'),
    ];
    my $before = dclone($events);

    my $first  = PJP::M::YearData->build($events, undef, 2025);
    is $events, $before, 'build がイベント列を変更しない';

    $first->{2010} = seed_year(
        [ entry(date => '2010-05-01 00:00:00', path => 'docs/modules/Ancient-1.00/Ancient.pod', in => 'Ancient') ],
        { alice => 1 });
    my $second = PJP::M::YearData->build($events, $first, 2025);

    is paths_of($second->{2025}), paths_of($first->{2025}), '2025 が変わらない';
    is paths_of($second->{2010}), ['docs/modules/Ancient-1.00/Ancient.pod'], '2010 も保たれる';
};

subtest '最新イベントより後の対象年を止める' => sub {
    # 回復手順 (script/create_data.pl <対象年>) の打ち間違いで未来年を渡すと、
    # 全イベントが対象年より前として捨てられ、seed をそのまま書き戻した結果が
    # 正常終了する。差分が出ないので「再導出は不要だった」と読めてしまう
    my @events = (entry(date => '2025-06-01 00:00:00', path => 'docs/modules/Foo-1.00/Foo.pod'));

    like dies { PJP::M::YearData->build(\@events, undef, 2052) },
        qr/after the newest translation event \(2025\)/,
        '最新イベントの年より後は die する';
    ok lives { PJP::M::YearData->build(\@events, undef, 2025) }, '最新イベントの年ちょうどは通る';
};

subtest '再利用する年ブロックの形を検査する' => sub {
    my $entry = entry(date => '2010-05-01 00:00:00', path => 'docs/modules/Old-1.00/Old.pod', in => 'Old');

    my $broken_module = { 2010 => seed_year([{ %$entry, author => undef }], { alice => 1 }) };
    like dies { PJP::M::YearData->build([], $broken_module, 2025) },
        qr/year 2010 is broken: a module entry has a broken author/,
        'module のフィールド欠けで die する';

    # 参照が入っていると Data::Dumper では書き戻せてしまい、表示側で初めて壊れる
    my $ref_module = { 2010 => seed_year([{ %$entry, name => ['Foo'] }], { alice => 1 }) };
    like dies { PJP::M::YearData->build([], $ref_module, 2025) },
        qr/a module entry has a broken name/, 'module のフィールドが参照でも die する';

    my $negative = { 2010 => seed_year([$entry], { alice => -1 }) };
    like dies { PJP::M::YearData->build([], $negative, 2025) },
        qr/alice has a broken count/, '件数が負の数なら die する';

    my $extra_author = { 2010 => seed_year([$entry], { alice => 1 }) };
    push @{$extra_author->{2010}{commit_count}}, ['bob', 1, 1];
    like dies { PJP::M::YearData->build([], $extra_author, 2025) },
        qr/bob is not in commit_count_all/, 'commit_count にだけ居る author で die する';

    my $missing_author = { 2010 => seed_year([$entry], { alice => 1, bob => 2 }) };
    shift @{$missing_author->{2010}{commit_count}};
    like dies { PJP::M::YearData->build([], $missing_author, 2025) },
        qr/disagree on the set of authors/, 'commit_count_all にだけ居る author で die する';

    my $duplicated = { 2010 => seed_year([$entry], { alice => 1 }) };
    push @{$duplicated->{2010}{commit_count}}, ['alice', 1, 1];
    like dies { PJP::M::YearData->build([], $duplicated, 2025) },
        qr/commit_count has alice twice/, '同じ author の行が 2 つあると die する';

    # 初出 dist が無かった年は 3 番目が undef のまま出力される (実データにもある)
    my $undef_first = { 2010 => seed_year([$entry], { alice => 1 }) };
    $undef_first->{2010}{commit_count}[0][2] = undef;
    ok lives { PJP::M::YearData->build([], $undef_first, 2025) }, '3 番目が undef の行は通る';

    # 更新はあったが初出 dist が無かった年は modules => [] になる
    my $empty_modules = { 2010 => seed_year([], { alice => 1 }) };
    ok lives { PJP::M::YearData->build([], $empty_modules, 2025) }, 'modules が空の年も通る';
};

subtest 'seed が原本として欠けていないか検査する' => sub {
    my $entry = entry(date => '2002-05-01 00:00:00', path => 'docs/modules/Old-1.00/Old.pod', in => 'Old');
    my $seed  = { 2002 => seed_year([$entry], { alice => 1 }) };

    ok lives { PJP::M::YearData->assert_seed_is_complete($seed, 2003) },
        '対象年の前年まで揃っていれば通る';

    like dies { PJP::M::YearData->assert_seed_is_complete(undef, 2003) },
        qr/no seed given/, 'seed が無ければ die する';
    like dies { PJP::M::YearData->assert_seed_is_complete({}, 2003) },
        qr/no seed given/, '空の seed でも die する';

    like dies { PJP::M::YearData->assert_seed_is_complete($seed, 2005) },
        qr/missing these years:\n  2003\n  2004/, '間の年が欠けていたら die する';

    like dies { PJP::M::YearData->assert_seed_is_complete({ %$seed, 'recent' => {} }, 2003) },
        qr/not plausible years/, '年でないキーがあれば die する';
    like dies { PJP::M::YearData->assert_seed_is_complete({ %$seed, 3000 => {} }, 2003) },
        qr/not plausible years/, '現在年より後のキーがあれば die する';
};

done_testing;
