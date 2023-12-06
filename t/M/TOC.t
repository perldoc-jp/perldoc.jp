use v5.38;
use Test2::V0;

use PJP::M::TOC;

subtest 'render_core - perl本体のドキュメントの目次' => sub {
    my $out = PJP::M::TOC->render_core();
    ok $out;
    note $out;
    todo '目次の内容を確認する' => sub {
        fail;
    };
};

#subtest 'render_function - 組み込み関数の目次' => sub {
#    my $out = PJP::M::TOC->render_function();
#    ok $out;
#
#};

# subtest 'render_variable - 組み込み変数の目次' => sub {
#     my $out = PJP::M::TOC->render_variable();
#     ok $out;
#     note $out;
# };

done_testing;
