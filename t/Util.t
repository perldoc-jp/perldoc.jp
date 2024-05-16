use v5.38;
use Test2::V0;

use PJP::Util qw(markdown_to_html);

subtest 'markdown_to_html' => sub {
    my $html = markdown_to_html(<<~'DOC');

    # h1

    ```perl
    say 'hello';
    ```

    - list1
    - list2

    DOC

    ok $html;
    note $html;
};

done_testing;
