use v5.38;
use Test2::V0;

use File::Temp qw/tempdir/;
use POSIX ();
use PJP::Util qw(markdown_to_html read_command write_file_atomic);

# 正常な 1 行を出してから指定の死に方をするコマンドを作り、その置き場所を返す
sub fake_bin {
    my ($name, @body) = @_;
    my $bin = tempdir(CLEANUP => 1);
    open my $fh, '>', "$bin/$name" or die $!;
    print $fh "#!/bin/sh\n", map { "$_\n" } @body;
    close $fh;
    chmod 0755, "$bin/$name" or die $!;
    return $bin;
}

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
    is slurp_file($path), "first\n", '書き出せる';

    write_file_atomic($path, sub { print {$_[0]} "second\n" });
    is slurp_file($path), "second\n", '上書きできる';
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

    is slurp_file($path), "original\n", '既存の内容が残る';
    is [grep { !m{/out\.txt$} } glob("$dir/*")], [], '一時ファイルが残らない';
};

sub slurp_file {
    open my $fh, '<', $_[0] or die $!;
    return do { local $/; <$fh> };
}

done_testing;
