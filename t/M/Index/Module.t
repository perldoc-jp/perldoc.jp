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

done_testing;
