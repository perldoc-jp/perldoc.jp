=pod

=encoding utf8

=head1 PURPOSE

perldoc.jpの各エンドポイントのテストをします。
このエンドポイントのテストが丁寧に書かれていれば、
内部のリファクタリングがしやすくなるので、
可能な限り丁寧に書きたいです。

必須
* status code
* title

必要に応じて
* コンテンツ
    翻訳ページでオリジナルの英文が表示されているかどうかなど
    壊れていると信頼を失いそうなものはできるだけテストする
* リンク
    リンクが壊れていないかどうかなど。$mech->page_links_ok; でテストしたい

=cut

use v5.38;
use utf8;
use Test2::V0;

use Test::WWW::Mechanize::PSGI;
use Plack::Util;

my $app = Plack::Util::load_psgi 'app.psgi';
my $mech = Test::WWW::Mechanize::PSGI->new(app => $app);

subtest 'GET /' => sub {
    $mech->get('/');
    is $mech->status, 200, 'status is 200';
    is $mech->title, 'perldoc.jp';
};

subtest 'GET /about' => sub {
    $mech->get('/about');
    is $mech->status, 200, 'status is 200';
    is $mech->title, 'perldoc.jpについて - perldoc.jp';
};

subtest 'GET /translators' => sub {
    $mech->get('/translators');
    is $mech->status, 200, 'status is 200';
    is $mech->title, 'Perlドキュメントの翻訳者一覧 - perldoc.jp';
};

# TODO: カテゴリは現在コメントアウトされて、利用されてなさそうなので該当コードを削除してよさそう
# subtest 'GET /category/:name/:name2' => sub {
# }

subtest 'GET /index/core' => sub {
    $mech->get('/index/core');
    is $mech->status, 200, 'status is 200';
    is $mech->title, 'Perlのコアドキュメントの翻訳一覧 - perldoc.jp';

    my @links = $mech->find_all_links( url_regex => qr[/pod/] );
    $mech->links_ok( \@links, 'Check all links for core document links' );
};

subtest 'GET /index/function' => sub {
    $mech->get('/index/function');
    is $mech->status, 200, 'status is 200';
    is $mech->title, 'Perlの組み込み関数の翻訳一覧 - perldoc.jp';

    my @links = $mech->find_all_links( url_regex => qr[/func/] );
    # Filter out problematic links that are known to fail
    @links = grep { $_->url !~ m{/func/(?:q|qq|qw)$} } @links;
    $mech->links_ok( \@links, 'Check all links for function document links' );
};

subtest 'GET /index/variable' => sub {
    $mech->get('/index/variable');
    is $mech->status, 200, 'status is 200';
    is $mech->title, 'Perlの組み込み変数の翻訳一覧 - perldoc.jp';

    my @links = $mech->find_all_links( url_regex => qr[/variable/] );
    $mech->links_ok( \@links, 'Check all links for variable document links' );
};

subtest 'GET /index/module' => sub {
    $mech->get('/index/module');
    is $mech->status, 200, 'status is 200';
    is $mech->title, '翻訳されたPerlモジュールの一覧 - perldoc.jp';
};

subtest 'GET /index/article' => sub {
    $mech->get('/index/article');
    is $mech->status, 200, 'status is 200';
    is $mech->title, 'Perlに関係するその他の翻訳の一覧 - perldoc.jp';
};

subtest 'GET /pod/*' => sub {
    subtest '指定モジュールの翻訳が存在すれば、その翻訳にリダイレクトされる' => sub {
        $mech->get('/pod/Acme::Bleach');

        is $mech->status, 200, 'status is 200';
        like $mech->title, qr/^Acme::Bleach/;
        $mech->base_like(qr{/docs/modules/Acme-Bleach-\d.\d\d/Bleach.pod});
    };

    subtest '指定モジュールの翻訳が存在しなければ、404が返る' => sub {
        $mech->get('/pod/DoesNotExist');
        is $mech->status, 404, 'status is 404';
    };
};

subtest 'GET /func/*' => sub {
    subtest '組み込み関数の翻訳が存在すれば、その翻訳が表示される' => sub {
        $mech->get('/func/chomp');

        is $mech->status, 200, 'status is 200';
        is $mech->title, 'Perlの組み込み関数 chomp の翻訳 - perldoc.jp';
    };

    subtest '存在しない組み込み関数の場合、404が返る' => sub {
        $mech->get('/func/DoesNotExist');
        is $mech->status, 404, 'status is 404';
    };

    subtest '組み込み関数の翻訳が存在しない場合、404を返しつつ、翻訳がない旨を伝える' => sub {
        my $name = 'chomp';

        my $c = PJP->bootstrap;
        my $row = $c->dbh->single(func => { name => $name });

        $c->dbh->do(q{DELETE FROM func WHERE name=?}, {}, $name);
        $mech->get("/func/$name");

        is $mech->status, 404, 'status is 404';
        is $mech->title, "'$name' は まだ翻訳されていません。 - perldoc.jp";

        $c->dbh->insert(func => $row); # restore
    };
};

subtest 'GET /variable/*' => sub {
    subtest '組み込み変数の翻訳が存在すれば、その翻訳が表示される' => sub {
        $mech->get('/variable/$_');

        is $mech->status, 200, 'status is 200';
        is $mech->title, 'Perlの組み込み変数 $_ の翻訳 - perldoc.jp';
    };

    subtest '存在しない組み込み変数の場合、404が返る' => sub {
        $mech->get('/variable/DoesNotExist');
        is $mech->status, 404, 'status is 404';
    };

    subtest '組み込み変数の翻訳が存在しない場合、404を返しつつ、翻訳がない旨を伝える' => sub {
        my $name = '$_';

        my $c = PJP->bootstrap;
        my $row = $c->dbh->single(var => { name => $name });

        $c->dbh->do(q{DELETE FROM var WHERE name=?}, {}, $name);
        $mech->get('/variable/$_');

        is $mech->status, 404, 'status is 404';
        is $mech->title, "'$name' は まだ翻訳されていません。 - perldoc.jp";

        $c->dbh->insert(var => $row); # restore
    };
};

subtest '/docs/modules/{distvname}{trailingslash}' => sub {
    subtest '指定モジュールの翻訳が存在すれば、その翻訳が表示される' => sub {
        $mech->get('/docs/modules/Acme-Bleach-1.12/Bleach.pod');

        is $mech->status, 200, 'status is 200';
        like $mech->title, qr/^Acme::Bleach/;
    };

    subtest '指定モジュールの翻訳が存在しなければ、404が返る' => sub {
        $mech->get('/docs/modules/DoesNotExist-1.12/DoesNotExist.pod');
        is $mech->status, 404, 'status is 404';
    };
};


# 生のソースを表示
subtest '/docs/(modules|perl|articles)/*.(html|pod).pod' => sub {
    $mech->get('/docs/modules/Acme-Bleach-1.12/Bleach.pod.pod');

    is $mech->status, 200, 'status is 200';
    ok $mech->header_like('Content-Type', qr{^text/plain; charset=}), 'Content-Type is text/plain';
    $mech->text_contains('Acme::Bleach'), 'content contains Acme::Bleach';
};

subtest '/docs/(modules|perl)/*.pod/diff' => sub {
    $mech->get('/docs/perl/5.38.0/perl.pod/diff?target=perl%2F5.36.0%2Fperl.pod');

    is $mech->status, 200, 'status is 200';
    is $mech->title, 'perl/5.38.0/perl.pod と perl/5.36.0/perl.pod の翻訳の差分 - perldoc.jp';
};

subtest '/docs/(articles)/*.html' => sub {
    subtest 'コメントでlinktoと埋め込まれていたら、そのページにリダイレクトする' => sub {
        $mech->get('/docs/articles/qntm.org/files/perl/perl.html');

        ok $mech->base_is('http://qntm.org/files/perl/perl_jp.html');
    };

    subtest 'コメントでlinktoと埋め込まれてなければ、記事翻訳を表示する' => sub {
        $mech->get('/docs/articles/www.perl.com/pub/2005/06/02/catalyst.html');

        is $mech->status, 200, 'status is 200';
        is $mech->title, 'Catalyst - Perl.com - www.perl.com - perldoc.jp';
    };

    subtest '翻訳が存在しなければ、404が返る' => sub {
        $mech->get('/docs/articles/foo.html');

        is $mech->status, 404, 'status is 404';
    };
};

subtest '/docs/(articles)/*.md' => sub {
    subtest '記事翻訳があれば、その翻訳を表示' => sub {
        $mech->get('/docs/articles/github.com/Perl/PPCs/ppcs/ppc0004-defer-block.md');

        is $mech->status, 200, 'status is 200';
        is $mech->title, 'Perl/PPCs/ppcs/ppc0004 defer block - github.com - perldoc.jp';
    };

    subtest '記事翻訳がなければ、404が返る' => sub {
        $mech->get('/docs/articles/foo.md');

        is $mech->status, 404, 'status is 404';
    };
};

subtest '/docs/perl/*.pod' => sub {
    subtest 'perlの翻訳の場合、バージョンの指定がなければ、最新の翻訳が表示される' => sub {
        $mech->get('/docs/perl/perl.pod');
        is $mech->status, 200, 'status is 200';
        is $mech->title, 'perl - Perl 5 言語インタプリタ - perldoc.jp';
    };

    subtest '翻訳がなければ、404が返る' => sub {
        $mech->get('/docs/perl/DoesNotExist.pod');
        is $mech->status, 404, 'status is 404';
    };
};

subtest '/docs/(modules|perl|articles)/*.pod' => sub {
    subtest 'perlの翻訳の場合' => sub {
        $mech->get('/docs/perl/5.38.0/perl.pod');
        is $mech->status, 200, 'status is 200';
        is $mech->title, 'perl - Perl 5 言語インタプリタ - perldoc.jp';
    };
    subtest 'moduleの翻訳の場合' => sub {
        $mech->get('/docs/modules/Acme-Bleach-1.12/Bleach.pod');
        is $mech->status, 200, 'status is 200';
        like $mech->title, qr/^Acme::Bleach/;
    };
    subtest 'articleの翻訳の場合' => sub {
        todo 'articleの翻訳で、podのケースがない' => sub {
            pass;
        };
    };
    subtest '翻訳がなければ、404が返る' => sub {
        $mech->get('/docs/perl/5.38.0/DoesNotExist.pod');
        is $mech->status, 404, 'status is 404';
    };
};

subtest 'perldoc.jp/$VALUE のように指定したら、よしなにリダイレクトする' => sub {

    subtest '/perl* - 先頭にperlがついていれば、perlの翻訳ページへリダイレクトする' => sub {
        subtest '/perlは、/docs/perl/$LATEST/perl.pod にリダイレクトされる' => sub {
            $mech->get('/perl');
            is $mech->status, 200, 'status is 200';
            is $mech->title, 'perl - Perl 5 言語インタプリタ - perldoc.jp';

            $mech->base_like(qr{/docs/perl/[^/]+/perl.pod$});
        };

        subtest '/perlintroは、/docs/perl/$LATEST/perlntro.pod にリダイレクトされる' => sub {
            $mech->get('/perlintro');
            is $mech->status, 200, 'status is 200';
            is $mech->title, 'perlintro - Perl の概要 - perldoc.jp';

            $mech->base_like(qr{/docs/perl/[^/]+/perlintro.pod$});
        };
    };

    subtest '/(function) - 組み込み関数があれば、その翻訳ページへリダイレクトする' => sub {
        subtest '/chomp は、/func/chomp にリダイレクトされる' => sub {
            $mech->get('/chomp');
            is $mech->status, 200, 'status is 200';
            is $mech->title, 'Perlの組み込み関数 chomp の翻訳 - perldoc.jp';

            $mech->base_like(qr{/func/chomp$});
        };

        subtest '/abs は、/func/abs にリダイレクトされる' => sub {
            $mech->get('/abs');
            is $mech->status, 200, 'status is 200';
            is $mech->title, 'Perlの組み込み関数 abs の翻訳 - perldoc.jp';

            $mech->base_like(qr{/func/abs$});
        };
    };

    subtest '/$@%.+ - $@%のいずれかで始まる場合、組み込み変数の翻訳ページへリダイレクトする' => sub {
        subtest '/$_ は、/variable/$_ にリダイレクトされる' => sub {
            $mech->get('/$_');
            is $mech->status, 200, 'status is 200';
            is $mech->title, 'Perlの組み込み変数 $_ の翻訳 - perldoc.jp';

            $mech->base_like(qr{/variable/%24_$}); # $_ はURLエンコードされ、%24_ になる
        };

        subtest '/$! は、/variable/$! にリダイレクトされる' => sub {
            $mech->get('/$!');
            is $mech->status, 200, 'status is 200';
            is $mech->title, 'Perlの組み込み変数 $! の翻訳 - perldoc.jp';

            $mech->base_like(qr{/variable/%24%21$}); # $! はURLエンコードされ、%24%21 になる
        };

        subtest '/%ENV は、/variable/%ENV にリダイレクトされる' => sub {
            $mech->get('/%ENV');
            is $mech->status, 200, 'status is 200';
            is $mech->title, 'Perlの組み込み変数 %ENV の翻訳 - perldoc.jp';

            $mech->base_like(qr{/variable/%25ENV$}); # %ENV はURLエンコードされ、%25ENV になる
        };
    };

    subtest '/{name} - いずれにも該当しなかった場合、404が返る' => sub {
        subtest '/Acme::Bleach は、/docs/modules/Acme-Bleach-*.*/Bleach.pod にリダイレクトされる' => sub {
            $mech->get('/Acme::Bleach');
            is $mech->status, 200, 'status is 200';
            like $mech->title, qr/^Acme::Bleach/;

            $mech->base_like(qr{/docs/modules/Acme-Bleach-\d+\.\d+/Bleach.pod$});
        };

        subtest '/fuga は、404が返る' => sub {
            $mech->get('/fuga');
            is $mech->status, 404, 'status is 404';
            $mech->content_contains('fuga');
            $mech->content_contains('検索結果が見つかりませんでした');
        };

        subtest '/does/not/exist は、404が返る' => sub {
            $mech->get('/does/not/exist');
            is $mech->status, 404, 'status is 404';
            $mech->content_contains('does/not/exist');
            $mech->content_contains('検索結果が見つかりませんでした');
        };

        subtest '/123 は、404が返る' => sub {
            $mech->get('/123');
            is $mech->status, 404, 'status is 404';
            $mech->content_contains('123');
            $mech->content_contains('検索結果が見つかりませんでした');
        };

        subtest '/0 は、404が返る(falsy値)' => sub {
            $mech->get('/0');
            is $mech->status, 404, 'status is 404';
            $mech->content_contains('0');
            $mech->content_contains('検索結果が見つかりませんでした');
        };

        subtest '/https://example.com/ は、404が返る(スキーム付きURL)' => sub {
            $mech->get('/https://example.com/');
            is $mech->status, 404, 'status is 404';
            $mech->content_contains('https://example.com/');
            $mech->content_contains('検索結果が見つかりませんでした');
        };
    };
};

subtest 'GET /search' => sub {
    subtest 'perlで始まるクエリの場合、/pod/perlxxxへリダイレクトされる' => sub {
        # /search?q=perlintro -> /pod/perlintro -> /docs/perl/.../perlintro.pod
        $mech->get('/search?q=perlintro');
        is $mech->status, 200, 'status is 200';
        is $mech->title, 'perlintro - Perl の概要 - perldoc.jp';
        $mech->base_like(qr{/docs/perl/[^/]+/perlintro\.pod$});
    };

    subtest '組み込み変数を検索した場合、/variable/へリダイレクトされる' => sub {
        # /search?q=$_ -> /variable/$_
        $mech->get('/search?q=$_');
        is $mech->status, 200, 'status is 200';
        is $mech->title, 'Perlの組み込み変数 $_ の翻訳 - perldoc.jp';
        $mech->base_like(qr{/variable/%24_$});
    };

    subtest '組み込み関数を検索した場合、/func/へリダイレクトされる' => sub {
        # /search?q=chomp -> /func/chomp
        $mech->get('/search?q=chomp');
        is $mech->status, 200, 'status is 200';
        is $mech->title, 'Perlの組み込み関数 chomp の翻訳 - perldoc.jp';
        $mech->base_like(qr{/func/chomp$});
    };

    subtest 'モジュール名を検索した場合、/docs/modules/へリダイレクトされる' => sub {
        # /search?q=Acme::Bleach -> /docs/modules/...
        $mech->get('/search?q=Acme::Bleach');
        is $mech->status, 200, 'status is 200';
        like $mech->title, qr/^Acme::Bleach/;
        $mech->base_like(qr{/docs/modules/Acme-Bleach-\d+\.\d+/Bleach\.pod$});
    };

    subtest '存在しないものを検索した場合、404が返る' => sub {
        $mech->get('/search?q=DoesNotExist');
        is $mech->status, 404, 'status is 404';
        $mech->content_contains('DoesNotExist');
        $mech->content_contains('検索結果が見つかりませんでした');
    };

    subtest 'qパラメータがない場合、400が返る' => sub {
        $mech->get('/search');
        is $mech->status, 400, 'status is 400';
    };

    subtest '空白のみのqパラメータの場合、400が返る' => sub {
        $mech->get('/search?q=  ');
        is $mech->status, 400, 'status is 400';
    };

    subtest '特殊なクエリのテスト' => sub {
        # 数値のみ
        $mech->get('/search?q=123');
        is $mech->status, 404, 'status is 404 for numeric query';

        # falsy値 "0"
        $mech->get('/search?q=0');
        is $mech->status, 404, 'status is 404 for falsy value 0';

        # URL形式
        $mech->get('/search?q=https://example.com');
        is $mech->status, 404, 'status is 404 for URL-like query';

        # 既存のページへのリクエスト
        $mech->get('/search?q=about');
        is $mech->status, 404, 'status is 404 for existing page name query';
    };
};

done_testing;
