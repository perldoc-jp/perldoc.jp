#!/usr/bin/env perl
# ビルド済みイメージを Cloud Run 相当の FS 制約 (--read-only + /tmp の tmpfs) で
# 起動し、主要経路の開通を確認する。deploy.yml (デプロイ前の検証) と test.yml
# (PR での runtime ビルド検証) が共用する。
#
# 使い方: script/smoke-test.pl <image>
#
# 結果は TAP で出力する。失敗時は diag で HTTP のステータス・本文の先頭・
# コンテナのログを出し、CI のログだけで原因を調査できるようにする。
# コンテナ起動前の検査と起動そのものの失敗は続行しても意味がないので
# Bail out! で打ち切るが、HTTP の各経路は独立に検査し、壊れている経路を
# 一度の実行で全部列挙する。
#
# CI ランナーのホスト側 (コンテナ外) で走るため、使ってよいのは core モジュール
# だけ (Test2::V0 が属する Test2::Suite は core に無い)
use v5.38;
use experimental qw(try defer);

# use utf8 は付けない。付けるとリテラル側だけが文字列 (デコード済み) になり、
# HTTP::Tiny が返すバイト列の本文と index() で一致しなくなる
use File::Basename qw(basename);
use File::Temp;
use HTTP::Tiny;
use Test::More;

# stderr は素通しにして、docker 自身のエラーがそのままログに残るようにする
sub capture (@cmd) {
    open my $fh, '-|', @cmd or die "fork @cmd: $!\n";
    my $out = do { local $/; <$fh> };
    close $fh;
    return ($? == 0, $out // '');
}

sub response_diagnostic ($response) {
    my $status = $response->{status} // '???';
    my $reason = $response->{reason} // '';
    my $body = substr($response->{content} // '', 0, 1000);

    return "HTTP $status $reason" if $body eq '';
    return "HTTP $status $reason\n応答またはエラー内容の先頭:\n$body";
}

sub check_get ($http, $base, $path, $marker = undef) {
    my $response = $http->get("$base$path");
    my $description = defined $marker
        ? "GET $path が '$marker' を含む"
        : "GET $path";
    my $passed = $response->{success}
        && (!defined $marker || index($response->{content}, $marker) >= 0);
    ok $passed, $description or diag response_diagnostic($response);
}

sub cleanup_container ($name, $show_logs) {
    # cleanup 内の外部コマンドで、元の例外や終了ステータスを上書きしない
    local $?;

    if ($show_logs) {
        diag "--- docker logs $name\n" . qx(docker logs $name 2>&1);
    }
    system "docker rm -f $name >/dev/null 2>&1";
}

sub smoke_test ($image) {
    # ホストと異なる platform のイメージ (Apple Silicon から本番の amd64 イメージ
    # を検査する場合など) では docker run のたびに platform mismatch の WARNING が
    # 出る。イメージ自身の platform を明示すると、動作を変えずに抑制できる。
    # イメージがまだ手元に無ければ従来どおり docker run の自動 pull に任せる
    # (deploy.yml は push だけで daemon に load しないのでこの分岐を通る)。
    # その場合の inspect のエラーは想定内なので stderr に出さない
    open my $stderr_backup, '>&', \*STDERR or die "dup STDERR: $!\n";
    open STDERR, '>', '/dev/null' or die "redirect STDERR: $!\n";
    my ($inspect_ok, $image_platform) = capture(
        qw(docker image inspect --format {{.Os}}/{{.Architecture}}), $image);
    open STDERR, '>&', $stderr_backup or die "restore STDERR: $!\n";
    chomp $image_platform;
    my @platform = $inspect_ok && $image_platform ne ''
        ? ('--platform', $image_platform) : ();

    # 非 root で起動すること (Dockerfile の USER の退行検出)。Cloud Run は
    # 任意 UID を強制しないため、イメージ側で保証する。
    # 出力が空 (docker 自体の失敗) や非数値を成功と誤認しないよう形式も検査する
    my ($id_ok, $uid) = capture(
        qw(docker run --rm), @platform, qw(--entrypoint id), $image, '-u');
    chomp $uid;
    ok($id_ok && $uid =~ /\A[0-9]+\z/ && $uid != 0,
        "非 root で起動する (uid=$uid)")
        or die "非 root で起動できない\n";

    # root 所有のアプリツリーへ Unix パーミッションとして書けないことも直接
    # 確かめる (--read-only mount の検査とは独立した保証。/tmp には書けること)
    my $perm = system(
        qw(docker run --rm), @platform, qw(--entrypoint sh), $image, '-ceu', <<'SH');
  test "$(id -u)" -ne 0
  if touch /usr/src/app/.permission-test 2>/dev/null; then
    echo "/usr/src/app is writable" >&2
    exit 1
  fi
  touch /tmp/.permission-test
SH
    ok($perm == 0, 'アプリツリーは書き込み不可で /tmp は書き込み可')
        or die "ファイルシステムの権限が要件を満たさない\n";

    # ホストの一時ディレクトリで名前を予約し、並行実行や PID の再利用による
    # 衝突を避ける。予約は cleanup が終わるまでこのスコープで保持する
    my $name_reservation = File::Temp->newdir(
        "smoke-$$-XXXXXXXX",
        TMPDIR => 1,
    );
    my $name = basename $name_reservation->dirname;

    my ($cleanup_needed, $started, $completed);
    defer {
        cleanup_container(
            $name,
            $started && (!$completed || !Test::More->builder->is_passing),
        ) if $cleanup_needed;
    }

    # docker run 中のシグナルも例外に変換し、defer の cleanup を通してから
    # 外側で Bail out! する。起動結果を受け取る前でも、Docker daemon 側では
    # コンテナが作られている可能性があるため、run より先に cleanup を有効にする
    my $abort = sub ($signal) { die "received SIG$signal\n" };
    local $SIG{INT}  = $abort;
    local $SIG{TERM} = $abort;
    local $SIG{HUP}  = $abort;

    $cleanup_needed = 1;

    # ホスト側ポートは固定しない。8080 固定だと docker compose (make up) が
    # bind している最中や並行実行と衝突する。127.0.0.1 への bind なので
    # テスト中のコンテナが LAN に公開されることもない
    my ($run_ok) = capture(qw(docker run -d --name), $name, @platform,
        qw(--read-only --tmpfs /tmp -e PORT=8080 -p 127.0.0.1::8080), $image);
    $run_ok or die "コンテナを起動できない\n";
    $started = 1;

    my ($port_ok, $port) = capture(qw(docker port), $name, '8080/tcp');
    ($port) = split /\n/, $port;
    $port_ok && $port or die "公開ポートを取得できない\n";
    my $base = "http://$port";
    pass "コンテナ起動 (--read-only + tmpfs /tmp, $base)";

    # ローカルコンテナだけを検査するので proxy 環境変数を無効化する。
    # redirect 先の成功で壊れた経路を見逃さないよう、直接の 2xx だけを成功とする
    my $http = HTTP::Tiny->new(
        timeout      => 5,
        max_redirect => 0,
        proxy        => undef,
        http_proxy   => undef,
    );

    # readiness は短い timeout で繰り返し、通常の endpoint は十分な余裕を持たせる
    my ($up, $last_response);
    for my $i (1 .. 30) {
        $last_response = $http->get("$base/");
        if ($last_response->{success}) {
            $up = $i;
            last;
        }
        sleep 2 if $i < 30;
    }
    if (!$up) {
        fail 'HTTP 応答待ち (2 秒間隔で最大 30 回)';
        diag response_diagnostic($last_response) if $last_response;
        die "起動を待ち切れなかった\n";
    }
    pass "HTTP 応答待ち ($up 回目の試行で応答)";

    $http->timeout(30);
    check_get($http, $base, '/', 'perldoc.jp');
    check_get($http, $base, '/docs/perl/perl.pod');
    check_get($http, $base, '/translators', '年</h2>');
    check_get($http, $base, '/static/docs.json', 'Acme::Bleach');
    # イメージへの static/favicon.ico の取り込み漏れを検出する
    check_get($http, $base, '/favicon.ico');
    # runtime の allowlist COPY の列挙漏れを検出する
    # (toc.txt / toc-var.txt はこの 2 ルートでしか読まれない)
    check_get($http, $base, '/index/core');
    check_get($http, $base, '/index/variable');
    # functions.txt と static/rss も runtime へ COPY するが、これらを読むルートは
    # prove では databuild の作業ツリー (どちらも存在する) で走るため、
    # COPY の抜けはここでしか検出できない
    check_get($http, $base, '/func/chomp', 'chomp');
    check_get($http, $base, '/static/rss/recent.rss', '<rss');
    # 差分表示は、外部コマンドの diff を fork し /tmp に一時ファイルを書く唯一の
    # ルート。prove は diffutils が必ず入っている databuild イメージ (slim ではない)
    # で走るため、slim の runtime で diff が引けることと、read-only FS + tmpfs の
    # /tmp に書けることは、ここでしか確かめられない。
    # 版の組は t/endpoints.t と同じものを使う (translation から失われた場合は
    # test ステージの prove が先に落ちる)
    check_get($http, $base,
        '/docs/perl/5.38.0/perl.pod/diff?target=perl%2F5.36.0%2Fperl.pod',
        "<table class='diff'>");

    $completed = 1;
}

@ARGV == 1 or die "usage: $0 <image>\n";
my ($image) = @ARGV;

try {
    smoke_test($image);
}
catch ($error) {
    my $message = "$error";
    chomp $message;
    BAIL_OUT $message;
}

done_testing;
