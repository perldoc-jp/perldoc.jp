package PJP::Web::Dispatcher;
use strict;
use warnings;
use utf8;

use Amon2::Web::Dispatcher::Lite;

use Log::Minimal;
use File::stat;
use Try::Tiny;
use Text::Xslate::Util qw/mark_raw/;

use PJP::M::TOC;
use PJP::M::Index::Module;
use PJP::M::Index::Article;
use PJP::M::Pod;
use PJP::M::PodFile;
use Text::Diff::FormattedHTML;

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

get '/manners' => sub {
    my $c = shift;
    return $c->render('manners.tt');
};

get '/translators' => sub {
    my $c = shift;
    return $c->render('translators.tt', {years => do 'data/years.pl'});
};

get '/category' => sub {
    my $c = shift;

    return $c->render('category.tt', {
                                   en2ja               => do "data/category_en2ja.pl",
                                   categorized_modules => do "data/category_data.pl",
                                  });
};


get '/category/:name' => sub {
    my ($c, $args) = @_;
    my $modules =  do "data/category_data.pl";
    return $c->render('category/index.tt', {
                                      en2ja    => do "data/category_en2ja.pl",
                                      category => $args->{name},
                                      modules  => $modules->{category_modules}->{$args->{name}},
                                     });
};

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

    my $toc = PJP::M::TOC->render($c);
    return $c->render('index/core.tt', {
        title => 'コアドキュメント - perldoc.jp',
        toc   => $toc,
    });
};

get '/index/function' => sub {
    my $c = shift;

    my $toc = PJP::M::TOC->render_function($c);
    return $c->render('index/function.tt' => {
        title => '組み込み関数 - perldoc.jp',
        toc   => $toc,
    });
};

# モジュールの目次
get '/index/module' => sub {
    my $c = shift;

    my $content = $c->cache->file_cache("index/module", PJP::M::Index::Module->cache_path($c), sub {
        my $index = PJP::M::Index::Module->get($c);
        $c->create_view->render(
            'index/module.tt' => {
                index => $index,
            }
        );
    });

    $c->render(
        'layout.html' => {
            title => '翻訳済モジュール - perldoc.jp',
            content => mark_raw($content),
        }
    );
};

# 記事の目次
get '/index/article' => sub {
    my $c = shift;

    my $content = $c->cache->file_cache("index/article", PJP::M::Index::Article->cache_path($c), sub {
        my $index = PJP::M::Index::Article->get($c);
        $c->create_view->render(
            'index/article.tt' => {
                index => $index,
            }
        );
    });

    $c->render(
        'layout.html' => {
            title => 'その他の翻訳 - perldoc.jp',
            content => mark_raw($content),
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
        return $c->res_404();
    }
    # my $is_old = $path !~ /delta/ && eval { version->parse($version) } < eval { version->parse("5.8.5") };

    return $c->redirect("/docs/$path");
};

use PJP::M::BuiltinFunction;
get '/func/*' => sub {
    my ($c, $p) = @_;
    my ($name) = @{$p->{splat}};

    my ($version, $html) = PJP::M::BuiltinFunction->retrieve($name);
    if ($version && $html) {
        return $c->render(
            'pod.tt' => {
                body         => mark_raw($html),
                title        => "$name 【perldoc.jp】",
                'PodVersion' => "perl-$version",
            },
        );
    } else {
        my $res = $c->show_error("'$name' は Perl の組み込み関数ではありません。");
        $res->code(404);
        return $res;
    }
};

get '/docs/modules/{distvname:[A-Za-z0-9._-]+}{trailingslash:/?}' => sub {
    my ($c, $p) = @_;
    my $distvname = $p->{distvname};

    my @rows = PJP::M::PodFile->search_by_distvname($distvname);
    unless (@rows) {
        warnf("Unknonwn distvname: $distvname");
        return $c->res_404();
    }

    return $c->render(
        'directory_index.tt' => {
            index     => \@rows,
            distvname => $distvname,
            'title'   => "$distvname 【perldoc.jp】",
        }
    );
};

# .pod.pod の場合は生のソースを表示する
get '/docs/{path:(modules|perl)/.+\.pod}.pod' => sub {
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

    my $pod = PJP::M::PodFile->retrieve($origin);

    my $origin_content = PJP::M::PodFile->slurp($origin) // return $c->res_404();
    my $target_content = PJP::M::PodFile->slurp($target) // return $c->res_404();

    my ($origin_charset) = ($origin_content =~ /=encoding\s+(euc-jp|utf-?8)/);
        $origin_charset //= 'utf-8';
    my ($target_charset) = ($target_content =~ /=encoding\s+(euc-jp|utf-?8)/);
        $target_charset //= 'utf-8';

    $origin_content = Encode::decode($origin_charset, $origin_content);
    $target_content = Encode::decode($target_charset, $target_content);

    my $diff = diff_strings { vertical => 1 }, $target_content, $origin_content;
    return $c->render('diff.tt',
                      {
                       diff      => mark_raw( $diff ),
                       origin    => $origin,
                       target    => $target,
                       package   => $pod->{package},
                       distvname => $pod->{distvname},
                      }
                     );
};

get '/docs/{path:articles/.+\.html}' => sub {
    my ($c, $p) = @_;
    my $pod = PJP::M::PodFile->retrieve($p->{path}) // return $c->res_404();
    my $html = PJP::M::PodFile->slurp($p->{path})   // return $c->res_404();


    $html =~s{^.*<(?:body).*?>}{}s;
    $html =~s{</(?:body)>.*$}{}s;

    # todo: use proper module
    $html =~s{<(?:script|style).+?</(?:script|style)>}{}gsi;
    $html =~s{<(?:script|style|link|meta)[^>]+>}{}gsi;
    $html =~s{<[^>]+on\w+[^>]+>.*$}{}gsi;
    $html =~s{<[^>]+style[^>]+>.*$}{}gsi;

    return $c->render('pod.tt',
                      {
                       is_article   => 1,
                       body         => mark_raw( $html ),
                       distvname    => $pod->{distvname},
                       package      => $pod->{package},
                       description  => $pod->{description},
                       'PodVersion' => $pod->{distvname},
                       'title'      => "$pod->{package} - $pod->{description} 【perldoc.jp】",
                       repository   => $pod->{repository},
                       path         => $pod->{path},
                      }
                     );
};

get '/docs/{path:(modules|perl|articles)/.+\.pod}' => sub {
    my ($c, $p) = @_;

    my $pod = PJP::M::PodFile->retrieve($p->{path});
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
                is_article   => ($p->{path} =~m{articles} ? 1 : 0),
                body         => mark_raw( $pod->{html} ),
                others       => \@others,
                distvname    => $pod->{distvname},
                package      => $pod->{package},
                description  => $pod->{description},
                'PodVersion' => $pod->{distvname},
                'title' =>
                  "$pod->{package} - $pod->{description} 【perldoc.jp】",
                repository => $pod->{repository},
                path       => $pod->{path},
            }
        );
    } else {
        return $c->res_404();
    }
};

get '/perl*' => sub {
    my ($c, $p) = @_;
    my ($splat) = @{$p->{splat}};
    return $c->redirect("/pod/perl$splat");
};

my $re = join('|', qw(
  -r -w -x -o -R -W -X -O -e -z -s -f -d -l -p
  -S -b -c -t -u -g -k -T -B -M -A -C
  abs accept alarm atan bind binmode bless break caller chdir chmod chomp chop chown chr chroot close closedir connect
  continue cos crypt dbmclose dbmopen defined delete die do dump each endgrent endhostent endnetent endprotoent endpwent
  endservent eof eval bynumber getprotoent getpwent getpwnam getpwuid getservbyname getservbyport getservent
  getsockname getsockopt glob gmtime goto grep hex import index int ioctl join keys kill last lc lcfirst length link
  listen local localtime lock log lstat m map mkdir msgctl msgget msgrcv msgsnd my next no oct open opendir ord order
  our pack package pipe pop pos precision print printf prototype push q qq qr quotemeta qw qx rand read readdir readline
  readlink readpipe recv redo ref rename require reset return reverse rewinddir rindex rmdir s say scalar seek seekdir select
  semctl semget semop send setgrent sethostent setnetent setpgrp setpriority setprotoent setpwent setservent setsockopt shift
  shmctl shmget shmread shmwrite shutdown sin size sleep socket socketpair sort splice split sprintf sqrt srand stat state
  study sub substr symlink syscall sysopen sysread sysseek system syswrite tell telldir tie tied time times tr truncate uc
  ucfirst umask undef unlink unpack unshift untie use utime values vec vector wait waitpid wantarray warn write y
));
get "/{name:$re}" => sub {
    my ($c, $p) = @_;

    return $c->redirect("/func/$p->{name}");
};

1;
