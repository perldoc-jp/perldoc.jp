use v5.38;
use utf8;
use Test2::V0;

use version ();
use PJP;
use PJP::DBI;
use PJP::M::PodFile;

# 版選択 (_version / get_latest / other_versions) の契約を fixture で検証する。
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

subtest '_version: distvname の正規化' => sub {
    my $v = \&PJP::M::PodFile::_version;
    ok $v->('5.42.0') == version->new('5.42.0'), 'perl コアの distvname はそのまま';
    ok $v->('HTTP-Message-6.03') == version->new('6.03'), 'dist 名 prefix を剥がす';
    ok $v->('libwww-perl-5.836') == version->new('5.836'), '複数ハイフンの dist 名も剥がす';
    ok $v->('Foo-Bar-v1.2.3') == version->new('v1.2.3'), 'v プレフィクス付きの版';
    ok $v->('Foo-1.2-RC1') == version->new('1.2'), 'RC サフィックスを剥がす';
    ok $v->('README') == version->new(0), '無版は最古 (0) 扱いで croak しない';
    ok $v->('BerkeleyDB-Lite-1_10') == version->new(0), 'parse できない表記も 0 扱い';
};

done_testing;
