use v5.38;
use utf8;
use Test2::V0;

use version ();
use PJP;
use PJP::DBI;
use PJP::M::PodFile;

# 版選択 (_version / pick_latest / get_latest / get_latest_pod / other_versions)
# の契約を fixture で検証する。
# 要点は「選択が pod テーブルの行順に依存しない」こと。実 DB の行順は INSERT 順や
# スキーマ (インデックスの走査順) で変わるため、ここが曖昧だと、アプリが表示する
# 版と、get_latest に従う static/docs.json の両方がスキーマ変更で黙って古い版に
# 化ける。fixture にはあえてインデックスを張らず全クエリをテーブルスキャン
# (= 挿入順) にした上で、同じ行集合を正順と逆順の両方で挿入して検証する。

my $c = PJP->bootstrap;

# [package, distvname, path] の行集合だけを持つ in-memory DB に差し替えて
# $cb を実行する。コンテキストの dbh は local で退避するので実 DB には触らない
sub with_pod_rows {
    my ($rows, $cb) = @_;
    for my $ordered ([@$rows], [reverse @$rows]) {
        my $dbh = PJP::DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {});
        $dbh->do(q{
            CREATE TABLE pod (
                package     varchar(255) not null,
                description varchar(255),
                path        varchar(255) not null PRIMARY KEY,
                distvname   varchar(255) not null,
                repository  varchar(255) not null,
                html        text
            )
        });
        my $sth = $dbh->prepare('INSERT INTO pod (package, distvname, path, repository) VALUES (?, ?, ?, ?)');
        $sth->execute(@$_, 'perl') for @$ordered;
        local $c->{db} = $dbh;
        $cb->();
    }
}

subtest 'perl コアの版は数値で比較される' => sub {
    # 5.6.1 は辞書順なら 5.42.0 より大きい。文字列比較と結果が分かれる組
    with_pod_rows [
        ['perlapio', '5.6.1',  'perl/5.6.1/perlapio.pod'],
        ['perlapio', '5.28.0', 'perl/5.28.0/perlapio.pod'],
        ['perlapio', '5.42.0', 'perl/5.42.0/perlapio.pod'],
    ], sub {
        is +PJP::M::PodFile->get_latest('perlapio'), 'perl/5.42.0/perlapio.pod',
            '5.42.0 が最新 (辞書順最大の 5.6.1 ではない)';
    };
};

subtest 'モジュールは dist 名を剥がした版で比較される' => sub {
    # 新しい版ほど dist 名の辞書順が小さい実例。HTTP-Message 6.03 は
    # libwww-perl から分離した後継 dist
    with_pod_rows [
        ['HTTP::Message', 'HTTP-Message-6.03', 'modules/HTTP-Message-6.03/HTTP/Message.pod'],
        ['HTTP::Message', 'libwww-perl-5.836', 'modules/libwww-perl-5.836/HTTP/Message.pod'],
        ['HTTP::Message', 'libwww-perl-5.813', 'modules/libwww-perl-5.813/HTTP/Message.pod'],
    ], sub {
        is +PJP::M::PodFile->get_latest('HTTP::Message'),
            'modules/HTTP-Message-6.03/HTTP/Message.pod',
            '6.03 > 5.836 (dist 名の辞書順に依らない)';
        is [map { $_->{distvname} } PJP::M::PodFile->other_versions('HTTP::Message')],
            ['HTTP-Message-6.03', 'libwww-perl-5.836', 'libwww-perl-5.813'],
            'other_versions も同じ比較で新しい順';
    };
};

subtest '版を持たない distvname が混ざっても決定的に選べる' => sub {
    # articles の README / ppc 文書は distvname に版を持たない
    # (実データの package "github.com")。croak せず path のタイブレークで
    # 常に同じ答えを返す
    with_pod_rows [
        ['github.com', 'README',               'articles/github.com/Perl/PPCs/README.md'],
        ['github.com', 'ppc0004-defer-block',  'articles/github.com/Perl/PPCs/ppcs/ppc0004-defer-block.md'],
        ['github.com', 'ppc0025-perl-version', 'articles/github.com/Perl/PPCs/ppcs/ppc0025-perl-version.md'],
    ], sub {
        is +PJP::M::PodFile->get_latest('github.com'),
            'articles/github.com/Perl/PPCs/ppcs/ppc0025-perl-version.md',
            '無版どうしはタイブレークで決まり挿入順に依存しない';
    };
    with_pod_rows [
        ['Foo', 'README',   'articles/foo/README.md'],
        ['Foo', 'Foo-0.01', 'modules/Foo-0.01/Foo.pod'],
    ], sub {
        is +PJP::M::PodFile->get_latest('Foo'), 'modules/Foo-0.01/Foo.pod',
            '版を持つものは無版 (最古扱い) に勝つ';
    };
};

subtest 'final release が RC / TRIAL より優先される' => sub {
    # -RC1 を剥がした版は final と同値になるため、distvname の文字列降順だけ
    # では RC 側が勝ってしまう組
    with_pod_rows [
        ['Foo', 'Foo-1.2',       'modules/Foo-1.2/Foo.pod'],
        ['Foo', 'Foo-1.2-RC1',   'modules/Foo-1.2-RC1/Foo.pod'],
        ['Foo', 'Foo-1.2-TRIAL', 'modules/Foo-1.2-TRIAL/Foo.pod'],
    ], sub {
        is +PJP::M::PodFile->get_latest('Foo'), 'modules/Foo-1.2/Foo.pod',
            '同じ数値版なら final が最新になる';
        is [map { $_->{distvname} } PJP::M::PodFile->other_versions('Foo')]->[0],
            'Foo-1.2', 'other_versions の先頭も final';
    };
    with_pod_rows [
        ['Foo', 'Foo-1.2-RC1', 'modules/Foo-1.2-RC1/Foo.pod'],
        ['Foo', 'Foo-1.3-RC1', 'modules/Foo-1.3-RC1/Foo.pod'],
    ], sub {
        is +PJP::M::PodFile->get_latest('Foo'), 'modules/Foo-1.3-RC1/Foo.pod',
            'プレリリースしか無ければ新しいプレリリースが選ばれる';
    };
};

subtest '同一 (package, distvname) の複数 path は昇順の先頭が主文書' => sub {
    # 実データ: POE-0.26 の POE/Loop/*.pod は原文の NAME がすべて
    # POE::Loop::Event のままで、5 つの path が同じ (package, distvname) を持つ
    with_pod_rows [
        ['POE::Loop::Event', 'POE-0.26', 'modules/POE-0.26/POE/Loop/Event.pod'],
        ['POE::Loop::Event', 'POE-0.26', 'modules/POE-0.26/POE/Loop/Gtk.pod'],
        ['POE::Loop::Event', 'POE-0.26', 'modules/POE-0.26/POE/Loop/Select.pod'],
    ], sub {
        is +PJP::M::PodFile->get_latest('POE::Loop::Event'),
            'modules/POE-0.26/POE/Loop/Event.pod',
            'path 昇順の先頭が返り、挿入順に依存しない';
    };
};

subtest 'perldelta は最新の perl の delta に解決される' => sub {
    with_pod_rows [
        ['perl581delta',  '5.10.0', 'perl/5.10.0/perl581delta.pod'],
        ['perl5100delta', '5.10.0', 'perl/5.10.0/perl5100delta.pod'],
        ['perl5420delta', '5.42.0', 'perl/5.42.0/perl5420delta.pod'],
    ], sub {
        is +PJP::M::PodFile->get_latest('perldelta'), 'perl/5.42.0/perl5420delta.pod',
            'perldelta は最新 distvname の delta';
        is +PJP::M::PodFile->get_latest('perl581delta'), 'perl/5.10.0/perl581delta.pod',
            '個別の perl5NNdelta はその文書自身';
    };
};

subtest '存在しない package は undef' => sub {
    with_pod_rows [
        ['perlapio', '5.42.0', 'perl/5.42.0/perlapio.pod'],
    ], sub {
        is +PJP::M::PodFile->get_latest('No::Such::Module'), undef, 'undef が返る';
    };
};

subtest 'get_latest_pod: 版なし URL は数値版の最新に解決される (1 引数)' => sub {
    # GET /docs/perl/perlapio.pod の経路。ORDER BY distvname (文字列降順) だと
    # 5.6.1 が選ばれてしまう組
    with_pod_rows [
        ['perlapio', '5.6.1',  'perl/5.6.1/perlapio.pod'],
        ['perlapio', '5.28.0', 'perl/5.28.0/perlapio.pod'],
        ['perlapio', '5.42.0', 'perl/5.42.0/perlapio.pod'],
    ], sub {
        is +PJP::M::PodFile->get_latest_pod('perlapio.pod')->{path},
            'perl/5.42.0/perlapio.pod',
            '数値版の最新が選ばれる (辞書順最大の 5.6.1 ではない)';
    };
};

subtest 'get_latest_pod: dist 名を跨いだ後継が選ばれる (2 引数)' => sub {
    # GET /docs/modules/HTTP-Message/HTTP/Message.pod のような版なし URL で
    # retrieve が空振りしたときのフォールバック経路
    with_pod_rows [
        ['HTTP::Message', 'HTTP-Message-6.03', 'modules/HTTP-Message-6.03/HTTP/Message.pod'],
        ['HTTP::Message', 'libwww-perl-5.836', 'modules/libwww-perl-5.836/HTTP/Message.pod'],
        ['HTTP::Message', 'libwww-perl-5.813', 'modules/libwww-perl-5.813/HTTP/Message.pod'],
    ], sub {
        is +PJP::M::PodFile->get_latest_pod('HTTP-Message', 'HTTP/Message.pod')->{path},
            'modules/HTTP-Message-6.03/HTTP/Message.pod',
            '6.03 > 5.836 (dist 名の辞書順に依らない)';
    };
};

subtest 'get_latest_pod: 候補が無ければ undef' => sub {
    with_pod_rows [
        ['perlapio', '5.42.0', 'perl/5.42.0/perlapio.pod'],
    ], sub {
        is +PJP::M::PodFile->get_latest_pod('no-such.pod'), undef, 'undef が返る';
    };
};

subtest 'package 再解釈の最新 dist は pick_latest で選ぶ' => sub {
    # GET /docs/modules/{distvname} で distvname 一致が空振りし、package 名と
    # して再解釈する経路 (Dispatcher) の合成。search_by_packages の並びは
    # 文字列降順なので、先頭行をそのまま最新とみなしてはならない
    with_pod_rows [
        ['HTTP::Message', 'HTTP-Message-6.03', 'modules/HTTP-Message-6.03/HTTP/Message.pod'],
        ['HTTP::Message', 'libwww-perl-5.836', 'modules/libwww-perl-5.836/HTTP/Message.pod'],
    ], sub {
        my @cands = PJP::M::PodFile->search_by_packages(['HTTP::Message']);
        is +PJP::M::PodFile->pick_latest(\@cands)->{distvname},
            'HTTP-Message-6.03',
            '文字列順の先頭 (libwww-perl-5.836) ではなく数値版の最新';
    };
};

subtest '_version: distvname の正規化' => sub {
    my $v = \&PJP::M::PodFile::_version;
    ok $v->('5.42.0') == version->new('5.42.0'), 'perl コアの distvname はそのまま';
    ok $v->('HTTP-Message-6.03') == version->new('6.03'), 'dist 名 prefix を剥がす';
    ok $v->('libwww-perl-5.836') == version->new('5.836'), '複数ハイフンの dist 名も剥がす';
    ok $v->('Foo-Bar-v1.2.3') == version->new('v1.2.3'), 'v プレフィクス付きの版';
    ok $v->('Foo-1.2-RC1') == version->new('1.2'), 'RC サフィックスを剥がす';
    ok $v->('Foo-1.2-TRIAL') == version->new('1.2'), 'TRIAL サフィックスを剥がす';
    ok $v->('README') == version->new(0), '無版は最古 (0) 扱いで croak しない';
    ok $v->('BerkeleyDB-Lite-1_10') == version->new(0), 'parse できない表記も 0 扱い';
};

subtest '_is_stable: プレリリース判定' => sub {
    my $s = \&PJP::M::PodFile::_is_stable;
    ok $s->('HTTP-Message-6.03'), 'final release';
    ok !$s->('Foo-1.2-RC1'), 'RC';
    ok !$s->('Foo-1.2-TRIAL'), 'TRIAL';
    ok !$s->('ExtUtils-MakeMaker-6.55_02'), 'underscore 版は developer release';
    ok $s->('5.42.0'), 'perl コアの distvname';
    ok $s->('README'), '無版は stable 扱い (版比較には version 0 が先に効く)';
};

subtest 'developer release は同じ数値版の final より新しい' => sub {
    # 1.2_01 は 1.2 のリリース後に次の版へ向けて出るものなので、RC (final の
    # 前身) とは前後が逆になる。_is_stable では両方 unstable 扱いだが、
    # 数値としては 1.2_01 > 1.2 なので数値比較が先に決める
    with_pod_rows [
        ['Foo', 'Foo-1.2',    'modules/Foo-1.2/Foo.pod'],
        ['Foo', 'Foo-1.2_01', 'modules/Foo-1.2_01/Foo.pod'],
    ], sub {
        is +PJP::M::PodFile->get_latest('Foo'), 'modules/Foo-1.2_01/Foo.pod',
            '1.2_01 が 1.2 より後';
    };
};

subtest '版として解析できない distvname は 0 扱いのまま選べる' => sub {
    # 実データに存在する 3 例。いずれも package ごとの候補が 1 つだけなので、
    # 0 扱いでも表示される版は変わらない (候補が増えたら version 0 同士の
    # タイブレークで path 順に決まる)
    for my $distvname (qw/BerkeleyDB-Lite-1_10 CGI-Lite-2.001-emergencyrelease mod_perl-1.29_related/) {
        ok PJP::M::PodFile::_version($distvname) == version->new(0), "$distvname は 0 扱い";
    }

    with_pod_rows [
        ['CGI::Lite', 'CGI-Lite-2.001-emergencyrelease', 'modules/CGI-Lite-2.001-emergencyrelease/Lite.pod'],
    ], sub {
        is +PJP::M::PodFile->get_latest('CGI::Lite'),
            'modules/CGI-Lite-2.001-emergencyrelease/Lite.pod', '単独候補ならそのまま選ばれる';
    };
};

done_testing;
