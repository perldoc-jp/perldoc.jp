package PJP::Web::Dispatcher;
use strict;
use warnings;
use utf8;
use feature qw(state);

use Amon2::Web::Dispatcher::Lite;

use Log::Minimal;
use File::stat;
use Try::Tiny;
use Text::Xslate::Util qw/mark_raw/;

use PJP::Util qw(markdown_to_html);
use PJP::M::TOC;
use PJP::M::Index::Module;
use PJP::M::Index::Article;
use PJP::M::Pod;
use PJP::M::PodFile;
use Regexp::Common qw/URI/;
use URI::Escape qw/uri_escape/;
use Encode qw(decode_utf8);

get '/' => sub {
    my $c = shift;

    return $c->render('index.tt', {
                                   recent => do "data/recent.pl"
                                  });
};

get '/about' => sub {
    my $c = shift;
    return $c->render('about.tt');
};

get '/translators' => sub {
    my $c = shift;
    return $c->render('translators.tt', {years => do 'data/years.pl'});
};

# NOTE: 2021/12/27: search.cpan.orgからmetacpan.orgへの移行に伴い意味不明な分類になっていたので廃止
# get '/category' => sub {
#     my $c = shift;
#
#     return $c->render('category.tt', {
#                                    en2ja               => do "data/category_en2ja.pl",
#                                    categorized_modules => do "data/category_data.pl",
#                                   });
# };
#
# get '/category/:name' => sub {
#     my ($c, $args) = @_;
#     my $modules =  do "data/category_data.pl";
#     return $c->render('category/index.tt', {
#                                       en2ja    => do "data/category_en2ja.pl",
#                                       category => $args->{name},
#                                       modules  => $modules->{category_modules}->{$args->{name}},
#                                      });
# };

get '/category/:name/:name2' => sub {
    my ($c, $args) = @_;
    my $modules =  do "data/category_data.pl";
    my $name = $args->{name} . '/' . $args->{name2};
    return $c->render('category/index.tt', {
                                      category  => $name,
                                      modules   => $modules->{category_modules}->{$name},
                                     });
};

get '/index/core' => sub {
    my $c = shift;

    my $toc = $c->cache->get_or_set('index/core', sub {
        mark_raw(PJP::M::TOC->render_core());
    });

    return $c->render('index/core.tt', {
        header_title => 'Perlのコアドキュメントの翻訳一覧',
        description => '翻訳されたPerlのコアドキュメントの一覧',
        title => 'コアドキュメント',
        toc   => $toc,
    });
};

get '/index/function' => sub {
    my $c = shift;

    my $toc = PJP::M::TOC->render_function($c);
    return $c->render('index/function.tt' => {
        header_title => 'Perlの組み込み関数の翻訳一覧',
        description => '翻訳されたPerlの組み込み関数の一覧',
        title => '組み込み関数',
        toc   => $toc,
    });
};

get '/index/variable' => sub {
    my $c = shift;

    my $toc = PJP::M::TOC->render_variable($c);
    return $c->render('index/variable.tt' => {
        header_title => 'Perlの組み込み変数の翻訳一覧',
        title => '組み込み変数',
        toc   => $toc,
    });
};

# モジュールの目次
get '/index/module' => sub {
    my $c = shift;

    my $content = $c->cache->get_or_set('index/module', sub {
        my @data = PJP::M::Index::Module->generate($c);
        $c->create_view->render(
            'index/module.tt' => {
                index => \@data,
            }
        );
    });

    $c->render(
        'layout.html' => {
            title => '翻訳済モジュール',
            content => mark_raw($content),
            description => '翻訳されたPerlモジュールの一覧',
            header_title => '翻訳されたPerlモジュールの一覧',
        }
    );
};

# 記事の目次
get '/index/article' => sub {
    my $c = shift;

    my $content = $c->cache->get_or_set('index/article', sub {
        my @index = PJP::M::Index::Article->generate($c);
        $c->create_view->render(
            'index/article.tt' => {
                index => \@index,
            }
        );
    });

    $c->render(
        'layout.html' => {
            header_title => 'Perlに関係するその他の翻訳の一覧',
            title => 'その他の翻訳',
            content => mark_raw($content),
            description => 'Perlに関係するWebPageなど、コアドキュメントやモジュール以外の翻訳の一覧',
        }
    );
};

# 添付 pod の表示
get '/pod/*' => sub {
    my ($c, $p) = @_;
    my ($package) = @{$p->{splat}};

    my $path = PJP::M::PodFile->get_latest(
        $package
    );
    unless ($path) {
        warnf("the path is not found in database: %s", $package);
        return $c->res_404({package => $package});
    }
    # my $is_old = $path !~ /delta/ && eval { version->parse($version) } < eval { version->parse("5.8.5") };

    return $c->redirect("/docs/$path");
};

use PJP::M::BuiltinFunction;
get '/func/*' => sub {
    my ($c, $p) = @_;
    my ($name) = @{$p->{splat}};

    if (not PJP::M::BuiltinFunction->exists($name)) {
        my $res = $c->show_error("'$name' は Perl の組み込み関数ではありません。");
        $res->code(404);
        return $res;
    }

    my ($version, $html) = PJP::M::BuiltinFunction->retrieve($name);
    if ($version && $html) {
        return $c->render(
            'pod.tt' => {
                header_title => "Perlの組み込み関数 $name の翻訳",
                description  => "Perlの組み込み関数 $name の翻訳",
                has_original => ($html =~m{class="original"} ? 1 : 0),
                body         => mark_raw($html),
                title        => "$name",
                'PodVersion' => "perl-$version",
            },
        );
    } else {
        my $res = $c->show_error("'$name' は まだ翻訳されていません。");
        $res->code(404);
        return $res;
    }
};

use PJP::M::BuiltinVariable;
get '/variable/*' => sub {
    my ($c, $p) = @_;
    my ($name) = @{$p->{splat}};

    if (not PJP::M::BuiltinVariable->exists($name)) {
        my $res = $c->show_error("'$name' は Perl の組み込み変数ではありません。");
        $res->code(404);
        return $res;
    }

    my ($version, $html) = PJP::M::BuiltinVariable->retrieve($name);
    if ($version && $html) {
        return $c->render(
            'pod.tt' => {
                header_title => "Perlの組み込み変数 $name の翻訳",
                description  => "Perlの組み込み変数 $name の翻訳",
                has_original => ($html =~m{class="original"} ? 1 : 0),
                body         => mark_raw($html),
                title        => "$name",
                'PodVersion' => "perl-$version",
            },
        );
    } else {
        if (PJP::M::BuiltinVariable->exists($name)) {
            my $res = $c->show_error("'$name' は まだ翻訳されていません。");
            $res->code(404);
            return $res;
        }
    }
};

get '/docs/modules/{distvname:[A-Za-z0-9._-]+}{trailingslash:/?}' => sub {
    my ($c, $p) = @_;
    my $distvname = $p->{distvname};

    my @rows = PJP::M::PodFile->search_by_distvname($distvname);
    if (not @rows) {
        my $package = $distvname;
        $package =~s{-}{::}g;
        if (@rows = PJP::M::PodFile->search_by_packages([$package])) {
            @rows = PJP::M::PodFile->search_by_distvname($rows[0]->{distvname});
        }
        if (not @rows) {
            warnf("Unknonwn distvname: $distvname");
            return $c->res_404();
        }
    }

    return $c->render(
        'directory_index.tt' => {
            header_title   => "Perlモジュール $distvname の翻訳",
            index     => \@rows,
            distvname => $distvname,
            title     => "$distvname",
        }
    );
};

# .pod.pod の場合は生のソースを表示する
get '/docs/{path:(?:modules|perl|articles)/.+\.(?:pod|html)}.pod' => sub {
    my ($c, $p) = @_;

    my $content = PJP::M::PodFile->slurp($p->{path}) // return $c->res_404();

    my ($charset) = ($content =~ /=encoding\s+(euc-jp|utf-?8)/);
        $charset //= 'utf-8';

    $c->create_response(
        200,
        [
            'Content-Type'           => "text/plain; charset=$charset",
            'Content-Length'         => length($content),
        ],
        [$content]
    );
};

get '/docs/{path:(?:modules|perl)/.+\.pod}/diff' => sub {
    my ($c, $p) = @_;
    my $origin = $p->{path};
    my $target = $c->req->param('target');
    my $heavy_diff = PJP::M::Pod->select_heavy_diff($origin, $target);
    my $diff_info = {};
    my $diff_cost;
    if ($heavy_diff) {
	$diff_info = PJP::M::PodFile->retrieve($origin);
	if ($heavy_diff->{is_cached}) {
	    $diff_info->{diff} = $heavy_diff->{diff};
	} else {
	    $diff_info->{error} = 'timeout';
	}
    } else {
	$diff_cost = time;
	$diff_info = PJP::M::Pod->diff($origin, $target, {timeout => 6});
	$diff_cost = time - $diff_cost;
    }

    $diff_info->{origin} = $origin;
    $diff_info->{target} = $target;

    if (my $error = $diff_info->{error}) {
	my $status = 404;
	if ($error eq 'timeout') {
	    $status = 503;
	    PJP::M::Pod->save_as_heavy_diff($origin, $target);
	}
	return $c->render_with_status($status, 'diff.tt', $diff_info);
    } else {
	if ($diff_cost > 3) {
	    PJP::M::Pod->save_as_heavy_diff($origin, $target, $diff_info->{diff});
	}
	$diff_info->{diff} = mark_raw($diff_info->{diff});
	return $c->render('diff.tt', {
				      %$diff_info,
				      title        => "$origin と $target の差分",
				      header_title => "$origin と $target の翻訳の差分",
				     });
    }
};

get '/docs/{path:articles/.+\.html}' => sub {
    my ($c, $p) = @_;
    my $pod = PJP::M::PodFile->retrieve($p->{path}) // return $c->res_404();
    my $html = PJP::M::PodFile->slurp($p->{path})   // return $c->res_404();

    if (my ($linkto) = $html =~ m{<!--\s+linkto:\s*(http[^\s]+)\s+-->}) {
        if ($linkto =~ m/$RE{URI}{HTTP}/) {
            return $c->redirect($linkto);
        }
    }

    my ($title, $abstract) = $c->abstract_title_description($html);
    $html =~ s{^.*<(?:body)[^>]*>}{}si;
    $html =~ s{</(?:body)>.*$}{}si;

    # todo: use proper module
    $html =~ s{<(script|style).+?</\1>}{}gsi;
    $html =~ s{<(?:script|style|link|meta)[^>]+>}{}gsi;
    $html =~ s{(<[^>]+) on[^>]+=\s*(["']).*?\2([^>]*>)}{$1$3}gsi;
    $html =~ s{(<[^>]+) (?:id|style)\s*=\s*(["']).*?\2([^>]*>)}{$1$3}gsi;
    $html =~ s{class\s*=\s*(?:(["'])?([ \-\w]+)\1?)}{
      my $c = lc($2);
      my $pretty = $c =~ m{\bprettyprint\b};
      if ($c =~ m{\boriginal\b}) {
          'class="original"';
      } elsif (defined $pretty and $pretty) {
          'class="prettyprint"';
      } else {
          "";
      }
    }gsie;

    return $c->render('pod.tt',
                      {
                       is_article   => 1,
                       has_original => ($html =~ m{class="original"} ? 1 : 0),
                       body         => mark_raw( $html ),
                       distvname    => $pod->{distvname},
                       package      => $pod->{package},
                       description  => $abstract,
                       'PodVersion' => $pod->{distvname},
                       'title'      => Encode::decode('utf8', $title . ' - ' . $pod->{package}),
                       repository   => $pod->{repository},
                       path         => $pod->{path},
                      }
                     );
};

get '/docs/{path:articles/.+\.md}' => sub {
    my ($c, $p) = @_;
    my $pod = PJP::M::PodFile->retrieve($p->{path}) // return $c->res_404();
    my $src  = PJP::M::PodFile->slurp($p->{path})   // return $c->res_404();

    my ($title, $abstract) = $c->abstract_title_description_from_md($src);
    my $html = markdown_to_html($src);

    return $c->render('pod.tt',
                      {
                       is_article   => 1,
                       has_original => ($html =~ m{class="original"} ? 1 : 0),
                       body         => mark_raw( $html ),
                       distvname    => $pod->{distvname},
                       package      => $pod->{package},
                       description  => $abstract,
                       'PodVersion' => $pod->{distvname},
                       'title'      => Encode::decode('utf8', $title . ' - ' . $pod->{package}),
                       repository   => $pod->{repository},
                       path         => $pod->{path},
                      }
                     );
};


my $display_pod = sub {
    my ($c, $p) = @_;

    my $path = $p->{path};
    my $pod = PJP::M::PodFile->retrieve($path);
    if (not $pod and $p->{path} =~m{^modules/([^/]+)/(.+\.pod)$}) {
        my ($package, $pod_path) = ($1, $2);
        $pod = PJP::M::PodFile->get_latest_pod($package, $pod_path);
    }
    if ($pod) {
        my @others = do {
            if ($pod->{package}) {
                grep { $_->{distvname} ne $pod->{distvname} }
                  PJP::M::PodFile->other_versions( $pod->{package} );
            } else {
                ();
            }
        };

        return $c->render(
            'pod.tt' => {
                is_article   => ($path =~m{articles} ? 1 : 0),
                has_original => ($pod->{html} =~ m{class="original"} ? 1 : 0),
                body         => mark_raw( $pod->{html} ),
                others       => \@others,
                distvname    => $pod->{distvname},
                package      => $pod->{package},
                description  => $pod->{description},
                'PodVersion' => $pod->{distvname},
                'title'      => "$pod->{package} - $pod->{description}",
                repository   => $pod->{repository},
                path         => $pod->{path},
                'header_title' => "$pod->{package} - $pod->{description}",
            }
        );
    } else {
        return $c->res_404();
    }
};

get '/docs/perl/{path:.[^/]+\.pod}' => sub { # perl
    my ($c, $p) = @_;
    my $pod = PJP::M::PodFile->get_latest_pod($p->{path}) or return $c->res_404;;
    return $display_pod->($c, {path => $pod->{path}});
};

get '/docs/{path:(?:modules|perl|articles)/.+\.pod}' => $display_pod;

get '/perl*' => sub {
    my ($c, $p) = @_;
    my ($splat) = @{$p->{splat}};
    return $c->redirect("/pod/perl$splat");
};

# to avoid warning 'Complex regular subexpression recursion limit (32766) exceeded'
foreach my $function_regexp (@PJP::M::BuiltinFunction::REGEXP) {
    get "/{name:$function_regexp}" => sub {
        my ($c, $p) = @_;

        return $c->redirect("/func/$p->{name}");
    };
}

get "/{name:[\$\@\%].+}" => sub {
    my ($c, $p) = @_;

    return $c->redirect("/variable/" . uri_escape($p->{name}));
};

get '/{name:[A-Z-a-z][\w:]+}' => sub {
    my ($c, $p) = @_;
    if (my $path = PJP::M::PodFile->get_latest($p->{name})) {
        return $c->redirect('/docs/' . $path);
    }

    return $c->redirect('/func/' . $p->{name});
};

1;
