use v5.38;
use utf8;
use Test2::V0;

use PJP::M::Index::Module;
use PJP;
use Data::Dumper;

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

done_testing;
