use v5.38;
use utf8;
use Test2::V0;

use File::Temp qw/tempdir/;
use POSIX ();
use Encode ();
use JSON::XS ();
use PJP::Util qw(markdown_to_html read_command write_file_atomic record_perldoc_failure);

use lib 't/lib';
use Test::FakeBin qw/fake_bin/;
use Test::Slurp qw/slurp_bytes/;

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

subtest 'read_command は読み取り中の die で子を回収してから投げ直す' => sub {
    # 呼び出し元の alarm などで読み取りを中断したとき、子を殺さずに close すると
    # 出力し続ける子の終了を待ってしまい、タイムアウトが効かない
    # exec で sh 自身を置き換える (孫を残すとテストの出力パイプが開いたままになる)
    my $bin = fake_bin('slowcat', 'echo first', 'exec sleep 30');
    local $ENV{PATH} = "$bin:$ENV{PATH}";

    my $started = time;
    my $error = dies {
        read_command(['slowcat'], sub { die "stop reading\n" });
    };
    my $elapsed = time - $started;

    is $error, "stop reading\n", '元の例外がそのまま伝わる';
    ok $elapsed < 5, "子の終了を待たずに戻る (${elapsed}s)";
    is waitpid(-1, POSIX::WNOHANG()), -1, '回収し残した子プロセスがいない';
};

subtest 'read_command は TERM を無視する子も KILL で回収する' => sub {
    # trap は exec で失われるので短い sleep を回す (KILL 後に孫が残る時間を抑える)
    my $bin = fake_bin('stubborn', 'trap "" TERM', 'echo first', 'while :; do sleep 1; done');
    local $ENV{PATH} = "$bin:$ENV{PATH}";

    my $started = time;
    my $error = dies {
        read_command(['stubborn'], sub { die "stop reading\n" });
    };
    my $elapsed = time - $started;

    is $error, "stop reading\n", '元の例外がそのまま伝わる';
    ok $elapsed < 10, "TERM を無視されても戻る (${elapsed}s)";
    is waitpid(-1, POSIX::WNOHANG()), -1, '回収し残した子プロセスがいない';
};

subtest 'write_file_atomic は書き切ってから置き換える' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = "$dir/out.txt";

    write_file_atomic($path, sub { print {$_[0]} "first\n" });
    is slurp_bytes($path), "first\n", '書き出せる';

    write_file_atomic($path, sub { print {$_[0]} "second\n" });
    is slurp_bytes($path), "second\n", '上書きできる';
    is [grep { !m{/out\.txt$} } glob("$dir/*")], [], '一時ファイルが残らない';

    my $mode = (stat $path)[2] & 07777;
    is $mode, 0644, '読み取り可能なパーミッションになる';
};

subtest 'write_file_atomic は途中で失敗しても既存のファイルを壊さない' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = "$dir/out.txt";
    write_file_atomic($path, sub { print {$_[0]} "original\n" });

    like dies {
        write_file_atomic($path, sub {
            print {$_[0]} "partial";
            die "generation failed\n";
        });
    }, qr/generation failed/, '書き出し中の例外はそのまま伝わる';

    is slurp_bytes($path), "original\n", '既存の内容が残る';
    is [grep { !m{/out\.txt$} } glob("$dir/*")], [], '一時ファイルが残らない';
};

subtest 'write_file_atomic は書き込みの失敗を見逃さない' => sub {
    # print が失敗してもハンドルにエラーが残るだけで、返り値を見ていない
    # コールバックだと素通りする。書き損じたまま rename すると、既存の
    # ファイルが不完全な内容に置き換わる
    my $dir  = tempdir(CLEANUP => 1);
    my $path = "$dir/out.txt";
    write_file_atomic($path, sub { print {$_[0]} "original\n" });

    like dies {
        write_file_atomic($path, sub {
            my $fh = shift;
            close $fh;                 # 以降の print は必ず失敗する
            print {$fh} "never";
        });
    }, qr/Cannot write/, '書き込みに失敗したら die する';

    is slurp_bytes($path), "original\n", '既存の内容が残る';
    is [grep { !m{/out\.txt$} } glob("$dir/*")], [], '一時ファイルが残らない';
};

subtest 'write_file_atomic は後始末の失敗を見逃さない' => sub {
    # print と flush は成功しても close で失敗することがある (書き戻しは
    # close のタイミングで起きる)。バッファに何も溜めずに fd だけ落とすと、
    # その経路だけを再現できる
    my $dir  = tempdir(CLEANUP => 1);
    my $path = "$dir/out.txt";
    write_file_atomic($path, sub { print {$_[0]} "original\n" });

    like dies {
        write_file_atomic($path, sub { POSIX::close(fileno $_[0]) });
    }, qr/Cannot write/, 'close に失敗したら die する';

    is slurp_bytes($path), "original\n", '既存の内容が残る';
    is [grep { !m{/out\.txt$} } glob("$dir/*")], [], '一時ファイルが残らない';
};

subtest 'write_file_atomic はパーミッション設定の失敗を見逃さない' => sub {
    # 書き出しは終わっているのに chmod で失敗する状況を、一時ファイルを
    # 消して作る (rename まで進むと、読めないファイルが本番に出る)
    my $dir  = tempdir(CLEANUP => 1);
    my $path = "$dir/out.txt";
    write_file_atomic($path, sub { print {$_[0]} "original\n" });

    like dies {
        write_file_atomic($path, sub {
            my $fh = shift;
            print {$fh} "new";
            # File::Temp のオブジェクトはコールバックの引数からは辿れないので、
            # 同じディレクトリの一時ファイルを消す
            unlink glob("$dir/*.tmp");
        });
    }, qr/Cannot chmod/, 'chmod に失敗したら die する';

    is slurp_bytes($path), "original\n", '既存の内容が残る';
    is [grep { !m{/out\.txt$} } glob("$dir/*")], [], '一時ファイルが残らない';
};

subtest 'write_file_atomic は置き換えの失敗を見逃さない' => sub {
    # 置き換え先がディレクトリなら rename は失敗する
    my $dir  = tempdir(CLEANUP => 1);
    my $path = "$dir/out";
    mkdir $path or die $!;
    mkdir "$path/keep" or die $!;   # 空でないディレクトリは置き換えられない

    like dies { write_file_atomic($path, sub { print {$_[0]} "x" }) },
        qr/Cannot rename/, '置き換えに失敗したら die する';

    ok -d $path, '既存のものが残る';
    is [grep { !m{/out$} } glob("$dir/*")], [], '一時ファイルが残らない';
};

subtest 'Pod::Perldoc の検索失敗の仕分け' => sub {
    # 候補は pod の C<...> から拾った文字列なので、関数でも変数でもないものが
    # 混ざる。その「見つからない」だけを正常系として通し、それ以外は集めて
    # 呼び出し元に止めさせる (集めた分が空でなければ generate が die する)
    my @failures;
    record_perldoc_failure(\@failures, 'notafunc', "No documentation for perl function 'notafunc' found\n");
    record_perldoc_failure(\@failures, 'notavar',  "No documentation for perl variable 'notavar' found\n");
    # 変数の候補は「そもそも変数の形ではない」文言でも落ちる
    # (perlvar の C<...> には autoflush や見出しの断片も混ざる)
    record_perldoc_failure(\@failures, 'autoflush', "'autoflush' does not look like a Perl variable\n");
    is \@failures, [], '見つからないだけなら記録しない';

    record_perldoc_failure(\@failures, 'chomp', "Cannot open perlfunc.pod: Permission denied\n");
    is scalar @failures, 1, 'それ以外の失敗は記録する';
    like $failures[0], qr/^chomp: Cannot open/, '名前と原因が残る';
};

subtest 'writer に渡した非 ASCII が壊れずに書き出される' => sub {
    # 生成物 (docs.json / RSS) は decode 済みの文字列を受け取るので、
    # 層を付けずに書くとバイト列が内部表現任せになる
    my $dir = tempdir(CLEANUP => 1);

    write_file_atomic("$dir/out.json", sub {
        my $fh = shift;
        binmode $fh, ':raw';
        print {$fh} JSON::XS->new->canonical->utf8->encode({ 'Acme::日本語' => 'docs/日本語.pod' });
    });
    my $json = JSON::XS->new->utf8->decode(slurp_bytes("$dir/out.json"));
    is $json->{'Acme::日本語'}, 'docs/日本語.pod', 'JSON は strict な UTF-8 として読み戻せる';

    write_file_atomic("$dir/out.xml", sub {
        my $fh = shift;
        binmode $fh, ':encoding(UTF-8)';
        print {$fh} qq{<?xml version="1.0" encoding="UTF-8"?>\n<t>翻訳者</t>\n};
    });
    my $xml = Encode::decode('UTF-8', slurp_bytes("$dir/out.xml"), Encode::FB_CROAK);
    like $xml, qr{<t>翻訳者</t>}, 'XML も strict な UTF-8 として読み戻せる';
};

done_testing;
