use v5.38;
use utf8;
use Test2::V0;

use PJP::M::Index::Module;
use PJP;
use Data::Dumper;
use File::Path ();
use File::Temp ();

my $c = PJP->bootstrap;

subtest 'generate' => sub {
    my @out = PJP::M::Index::Module->generate($c);

    for my $out (@out) {
        my $name = $out->{name};
        my $ret = is $out, {
            name           => D,
            abstract       => E, # 本当は D にしたいが一部こけてる
            repository     => 'translation', # 現在、translation しかない
            latest_version => E,
            versions       => array {
                all_items {
                    name       => $name,
                    version    => D,
                    repository => 'translation',
                    abstract   => E,
                    distvname  => D,
                };
                etc;
            },
        }, $name;

        unless ($ret) {
            note Dumper($out);
        }
    }
};

subtest '祖先に assets/ があっても repository がずれない' => sub {
    # 文字列置換で assets/ より前を削る方式だと、ここで repository 名が
    # 1 つずれる (translation ではなく work になる)
    my $root   = File::Temp::tempdir(CLEANUP => 1);
    my $assets = "$root/assets/work/assets";
    my $dist   = "$assets/translation/docs/modules/Acme-Sample-1.00";
    File::Path::make_path($dist);
    open my $fh, '>:raw', "$dist/Sample.pod" or die $!;
    print {$fh} "=encoding utf-8\n\n=head1 NAME\n\nAcme::Sample - \x{e3}\x{81}\x{82}\n\n";
    close $fh;

    local $c->config->{assets_dir} = $assets;
    my @out = PJP::M::Index::Module->generate($c);

    is scalar(@out), 1, '1 件だけ拾う';
    is $out[0]{repository}, 'translation', '直下の checkout 名になる';
    is $out[0]{versions}[0]{distvname}, 'Acme-Sample-1.00', 'distvname はディレクトリ名';
};

subtest '版が同値でも並びが列挙順に落ちない' => sub {
    # compare_version は別 dist の同じ数値版や、版として解析できない名前どうしで
    # 0 を返す。その組の並びを readdir に委ねると versions の順序も
    # 先頭から採る abstract も環境依存になるので、distvname で締めている。
    #
    # 実データ (319 モジュール群) には比較同値の隣接組が無いため、
    # 生成物の完全一致ではこの退行を検出できない。synthetic fixture で見る
    my $root   = File::Temp::tempdir(CLEANUP => 1);
    my $assets = "$root/assets";
    my $mods   = "$assets/translation/docs/modules";

    # 同じ module 名 (Acme-Same) を持ち、版が同値になる distvname を 2 つ置く
    for my $dir (qw/Acme-Same-1.00 Acme-Same-1.0/) {
        File::Path::make_path("$mods/$dir");
        open my $fh, '>:raw', "$mods/$dir/Same.pod" or die $!;
        print {$fh} "=encoding utf-8\n\n=head1 NAME\n\nAcme::Same - same\n\n";
        close $fh;
    }

    local $c->config->{assets_dir} = $assets;

    # 同じ入力から 2 回作って、並びが揺れないことも見る
    my @first  = PJP::M::Index::Module->generate($c);
    my @second = PJP::M::Index::Module->generate($c);
    is \@second, \@first, '同じ入力からは同じ並びになる';

    # 入力順に依存しないことは _sort_versions を直接呼んで見る。
    # generate 経由だと Perl の sort が安定なため、タイブレークを外しても
    # readdir がたまたま期待どおりの順に返せば通ってしまう
    my @rows = ({ distvname => 'Acme-Same-1.0' }, { distvname => 'Acme-Same-1.00' });
    for my $order ([0, 1], [1, 0]) {
        my @input = @rows[@$order];
        is [map { $_->{distvname} } PJP::M::Index::Module->_sort_versions(\@input)],
           ['Acme-Same-1.00', 'Acme-Same-1.0'],
           "入力順 (@$order) に依らず distvname の降順で締める";
    }

    my ($same) = grep { $_->{name} eq 'Acme-Same' } @first;
    ok $same, 'Acme::Same が拾えている';
    is [map { $_->{distvname} } @{$same->{versions}}],
       ['Acme-Same-1.00', 'Acme-Same-1.0'],
       '版が同値なら distvname の降順で締める';
};

done_testing;
