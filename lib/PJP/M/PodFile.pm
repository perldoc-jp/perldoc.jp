use strict;
use warnings;
use utf8;
use feature qw(state);

package PJP::M::PodFile;
use Amon2::Declare;
use File::Spec::Functions qw/abs2rel catfile catdir/;
use File::Find::Rule;
use PJP::M::Pod;
use Log::Minimal;
use File::Basename;
use version;
use PJP::M::Index::Article;
use PJP::M::BuiltinFunction;
use PJP::M::Repository;
use PJP::Util qw(markdown_to_html);

sub slurp {
    my ($class, $path) = @_;
    my $c = c();

    # インデックスされてるか確認する
    my ($cnt) = $c->dbh->selectrow_array(q{SELECT COUNT(*) FROM pod WHERE path=?}, {}, $path);
    return undef unless $cnt;

    my ($fullpath) = glob(catdir($c->assets_dir(), '*', 'docs', $path));
    return undef unless -f $fullpath;

    open my $fh, '<', $fullpath or die "Cannot open file: $fullpath";
    return scalar(do { local $/; <$fh> });
}

sub retrieve {
        my ($class, $path) = @_;

        my $c = c();
        $c->dbh->single(
                'pod' => {
                        path => $path,
                },
        );
}

# distvname を比較可能な version 値にする。バージョンを持たない distvname
# (articles の README や ppc 文書等) は croak せず最古扱いにする。croak だと
# 無版の文書が混在する package (github.com) で版選択そのものができなくなる
sub _version {
    my ($v) = @_;
    $v =~ s{^.+?-(?=\d)}{};
    $v =~ s{\-(?:RC\d+|TRIAL)$}{}i;
    $v =~ s{^.+?-(v[\d\.]+)$}{$1}i;
    return eval { version->new($v) } // version->new(0);
}

# final release かどうか。-RC1 等を剥がした _version は final と同値になる
# ため、単体では最新版の選択に使えない
sub _is_stable {
    my ($v) = @_;
    return 0 if $v =~ m{\-(?:RC\d+|TRIAL)$}i;
    # 6.55_02 のような underscore 版は CPAN の developer release
    return 0 if _version($v)->is_alpha;
    return 1;
}

# distvname 同士の版比較 ($x の方が新しければ正)。版の比較はこの関数に
# 一本化する (other_versions / get_latest / script/create_data.pl が
# 同じ選択をする)。同じ数値版では final release がプレリリースより新しい側に
# 来る (Foo-1.2-RC1 より Foo-1.2 が新しい)
sub _compare_version {
    my ($x, $y) = @_;
    state (%version, %stable);
    return ($version{$x} //= _version($x)) <=> ($version{$y} //= _version($y))
        || ($stable{$x} //= _is_stable($x)) <=> ($stable{$y} //= _is_stable($y));
}

# 候補行の集合から最新の 1 行を選ぶ (無ければ undef)。行は path / distvname /
# package を持つこと。「最新」の選択はここに一本化する (get_latest /
# get_latest_pod / Dispatcher の package 再解釈が同じ規則を通る)。SQL の
# ORDER BY distvname は文字列順で、perl コアの 5.6.1 が 5.42.0 に、
# libwww-perl-5.836 が HTTP-Message-6.03 に勝ってしまうため、最新の選択には
# 使えない。同値の版は distvname / package の降順で締め、同一 (package,
# distvname) に複数の path がある実データ (NAME が重複した dist 内の pod や
# articles の README 等) は path 昇順の先頭を主文書として選ぶ。path
# (PRIMARY KEY) まで比較すれば全順序なので、結果は常に決定的になる
sub pick_latest {
    my ($class, $rows) = @_;
    my ($latest) =
      sort  {
               _compare_version($b->{distvname}, $a->{distvname})
            || $b->{distvname} cmp $a->{distvname}
            || $b->{package} cmp $a->{package}
            || $a->{path} cmp $b->{path}
      } @$rows;
    return $latest;
}

sub other_versions {
        my ($class, $package) = @_;
        my $c = c();
        # 同値の版は path (PRIMARY KEY) でタイブレークし、並びを行順に依存させない
        # (昇順なのは get_latest の主文書の選択規則と同じ向きに揃えるため)
        if ($package =~ m{^perl.*?delta$}) {
            sort { _compare_version($b->{distvname}, $a->{distvname}) || $a->{path} cmp $b->{path} }
              grep {$_->{package} =~ m{^perl.*?delta$}}
                @{$c->dbh->selectall_arrayref(q{SELECT distvname, path, package FROM pod WHERE package like 'perl%delta'}, {Slice => {}})};
        } else {
            sort { _compare_version($b->{distvname}, $a->{distvname}) || $a->{path} cmp $b->{path} }
              @{$c->dbh->selectall_arrayref(q{SELECT distvname, path FROM pod WHERE package=?}, {Slice => {}}, $package)};
        }
}

sub get_latest {
        my ($class, $package) = @_;

        my $c = c();
        my ($where_operator, $search_package);
	my $search_column = 'package';
	if ($package eq 'perldelta') {
	  ($where_operator, $search_package) = ('like', 'perl%delta');
	} elsif ($package =~m{perl5(\d+)delta}) {
	  $search_column = 'path';
	  ($where_operator, $search_package) = ('like', "%/$package.pod");
	} else {
	  ($where_operator, $search_package) = ('=', $package);
	}

    my $latest = $class->pick_latest(
        $c->dbh->selectall_arrayref( qq{SELECT path, distvname, package FROM pod WHERE $search_column $where_operator ?},
            {Slice => {}}, $search_package )
    );
        unless ($latest) {
                debugf("Any versions not found in database: %s", $search_package);
                return undef;
        }
        return $latest->{path};
}

sub get_latest_pod {
    my $class = shift;
    my ($package, $pod_path);

    if (@_ == 1) {
        ($pod_path) = @_;
        $package  = $pod_path;
        $package  =~ s{\.pod}{};
    } else {
        ($package, $pod_path) = @_;
        $package =~s{-}{::}g;
        $pod_path =~ s{$package-[^/]+}{$package\%};
    }

    my $c = c();
    # 同じ pod の候補は dist を跨ぐ (HTTP/Message.pod は libwww-perl 5.x と
    # HTTP-Message 6.x の両方にある)。候補は軽いカラムだけで集めて
    # pick_latest で選び、選ばれた 1 行だけを retrieve で引き直す
    # (html を候補の行数ぶん読まないため)
    my $rows = $c->dbh->selectall_arrayref(
        q{SELECT path, distvname, package FROM pod WHERE package = ? AND path LIKE ?},
        {Slice => {}}, $package, '%' . $pod_path);
    my $latest = $class->pick_latest($rows) or return undef;
    return $class->retrieve($latest->{path});
}

sub search_by_distvname {
        my ($class, $distvname) = @_;
        my $c = c();
        @{ $c->dbh->selectall_arrayref(q{SELECT package, path, description FROM pod WHERE distvname=? ORDER BY package}, {Slice => {}}, $distvname) };
}

sub search_by_packages {
        my ($class, $packages) = @_;
        my $c = c();
        my $place_holder = join ',', (('?') x @$packages);
        # ORDER BY は package ごとのグルーピングと決定的な並びのため。
        # distvname の文字列降順は版の新旧を表さないので、最新の 1 行を
        # 選ぶ用途では pick_latest を通すこと
        @{ $c->dbh->selectall_arrayref(qq{SELECT path, package, description, distvname FROM pod WHERE package in ($place_holder) ORDER BY package, distvname desc}, {Slice => {}}, @$packages) };
}

sub generate {
        my ($class, $c) = @_;

        # perlfunc.pod の HTML には組み込み関数へのリンクを焼き込む (下の
        # generate_one_file)。一覧が空のまま生成すると、リテラル置換分だけが
        # 残った HTML が黙ってイメージに入る。
        # script/update.pl は PJP::M::BuiltinFunction->generate を先に実行し、
        # その最後で functions.txt を読み直すので、この時点では埋まっている
        die 'PJP::M::BuiltinFunction has no function list; run its generate() first'
            unless @PJP::M::BuiltinFunction::REGEXP;

        my @failures;
        my $txn = $c->dbh_master->txn_scope();
        $c->dbh_master->do(q{DELETE FROM pod});
        my @bases = (glob(catdir($c->assets_dir(), '*', 'docs')));
        for my $base (@bases) {
                # @bases は assets_dir 直下から glob しているので、必ず
                # assets_dir の中にある。文字列置換の成否で分岐していた頃は、
                # assets_dir の path に 'assets' component が無い環境
                # (テストの tempdir 等) だけ別の拡張子規則に落ちていた
                my $repository = PJP::M::Repository::repository_of($c, $base);
                # 何を翻訳文書として配信するかは、イベント観測・現ツリー列挙と
                # 同じ述語 (PJP::M::Repository) を通す
                my $extention_exp = PJP::M::Repository::TRANSLATION_FILE_RE;

                # 列挙順はファイルシステムに依存する。pod テーブルへの挿入順が
                # そのまま DB のバイト列に出るので、並べ替えて決定的にする
                my @files = sort File::Find::Rule->file()
                    ->name($extention_exp)
                    ->in($base);
                for my $file (@files) {
                    eval {
                        if ($file =~ m{\.pod$}) {
                            $class->generate_one_file($c, $file, $base, $repository);
                        } elsif ($file =~ m{\.md$}) {
                            $class->generate_one_file_md($c, $file, $base, $repository);
                        } else {
                            $class->generate_one_file_html($c, $file, $base, $repository);
                        }
                        1;
                    } or do {
                        # 1 ファイルの失敗で全体を止めず、最後にまとめて報告する。
                        # そのファイルだけ配信から欠ける状態でイメージが完成すると、
                        # 「500 件以上ある」程度のテストは通ってしまい気づけない
                        push @failures, "$file: " . ($@ || 'unknown error');
                    };
                }
        }

        # commit の前に判定する。後に置くと、失敗したビルドが部分的な pod
        # テーブルを確定させてしまう
        die "cannot generate these documents:\n"
            . join('', map { "  $_\n" } @failures)
            if @failures;

        $txn->commit;
}

sub generate_one_file {
        my ($class, $c, $file, $base, $repository) = @_;
        infof("Processing: %s", $file);
        my $args = do {
                    my $html = PJP::M::Pod->pod2html($file);
                    if ($file =~ m{/perlfunc\.pod$}) {
                        $html = PJP::M::BuiltinFunction->linkify_functions($html);
                    }
                    my $relpath = abs2rel( $file, $base );
                    my ( $package, $description ) =
                      PJP::M::Pod->parse_name_section($file);
                    if ( !defined $package ) {
                        warnf("Cannot get package name from %s", $file);
                        $package = $relpath;
                        $package =~ s/\.pod$//;
                        $package =~ s!^modules/!!;
                        $package =~ s!^articles/!!;
                    }
                    ( my $distvname = $relpath ) =~ s!^(modules|articles)/!!;

                    if ($repository =~ m{^Moose}) {
                        $relpath = 'modules/' . $relpath;
                    }

                    $distvname =~ s!^perl/!!;
                    $distvname =~ s!/.+!!;
                    +{
                        path        => $relpath,
                        package     => $package,
                        description => $description,
                        distvname   => $distvname,
                        html        => $html,
                    };
        };
        $c->dbh_master->replace(
                pod => +{
                        repository => $repository,
                        %$args
                },
        );
}

# it is not pod, but html ...
sub generate_one_file_html {
        my ($class, $c, $file, $base, $repository) = @_;
        infof("Processing: %s", $file);
        my $args = do {
                    my $html = PJP::M::Index::Article::slurp($file);
                    my $relpath = abs2rel( $file, $base );
                    my ($package, $distvname) = $relpath =~ m{^articles/([^/]+)/(?:.*?/)?([^/]+)\.html$};

                    $package or die "cannot get package name: $relpath";

                    $distvname =~ s!/.+!!;
                    +{
                        path        => $relpath,
                        package     => $package,
                        distvname   => $distvname,
                        html        => $html,
                    };
        };
        $c->dbh_master->replace(
                pod => +{
                        repository => $repository,
                        %$args
                },
        );
}

# it is not pod, but md ...
sub generate_one_file_md {
        my ($class, $c, $file, $base, $repository) = @_;
        infof("Processing: %s", $file);
        my $args = do {
                    my $md_src = PJP::M::Index::Article::slurp($file);
                    my $relpath = abs2rel( $file, $base );
                    my ($package, $distvname) = $relpath =~ m{^articles/([^/]+)/(?:.*?/)?([^/]+)\.md$};

                    $package or die "cannot get package name: $relpath";

                    my $html = markdown_to_html($md_src);

                    $distvname =~ s!/.+!!;
                    +{
                        path        => $relpath,
                        package     => $package,
                        distvname   => $distvname,
                        html        => $html,
                    };
        };
        $c->dbh_master->replace(
                pod => +{
                        repository => $repository,
                        %$args
                },
        );
}

1;

