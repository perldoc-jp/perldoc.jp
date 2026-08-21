use strict;
use warnings;
use utf8;
use 5.10.0;

# 目次データは script/create_data.pl がビルド時に data/index-article.pl へ生成する

package PJP::M::Index::Article;
use LWP::UserAgent;
use CPAN::DistnameInfo;
use Log::Minimal;
use URI::Escape qw/uri_escape/;
use JSON;
use File::Spec::Functions qw/catfile/;
use File::Find::Rule;
use File::Spec;
use version;
use autodie;
use PJP::M::Pod;
use PJP::M::Repository;
use Data::Dumper;
use Regexp::Common qw/URI/;
use PJP::Util qw/slurp/;

sub generate {
    my ($class, $c) = @_;

    # 情報をかきあつめる
    my @files;
    for my $base (map { File::Spec->catdir( $c->assets_dir(), $_) } qw(
        translation/docs/articles/
    )) {
        push @files, $class->_get_files($c, $base) if -d $base;
    }

    my @articles = $class->_generate($c, \@files);

    return  map {
        +{
          name     => $_->{name},
          abstract => $_->{abstract},
          repository => $_->{repository},
          distvname  => $_->{distvname},
          latest_version => 0,
          versions => [],
         }
    } @articles;
}

# 1 ファイルにつき 3 つの path を返す。
#
#   raw  読み書きに使う path。readdir/File::Find の生バイトのまま持ち、
#        Perl の再エンコード挙動に依存させない
#   rel  $base からの相対 path を decode したもの。distvname の素になり、
#        script/create_data.pl で decode 済みの翻訳イベント path と
#        突き合わせられる (生バイトのままだと非 ASCII のファイル名だけ
#        更新日時が付かない)
#   repository  assets_dir 直下のどの checkout に属するか
sub _get_files {
    my ($class, $c, $base) = @_;

    my $repository = PJP::M::Repository::repository_of($c, $base);

    opendir(my $dh, $base);
    my @raw_files;
    while (defined(my $e = readdir $dh)) {
        next if $e =~ /^\./;
        next if $e =~ /^CVS$/;

        push @raw_files, File::Find::Rule->file()
            ->name(PJP::M::Repository::TRANSLATION_FILE_RE)
            ->in("$base/$e");
    }
    closedir $dh;

    return map {
        +{
            repository => $repository,
            raw        => $_,
            rel        => PJP::M::Repository::decode_path(
                              File::Spec->abs2rel($_, $base)),
        }
    } @raw_files;
}

sub _generate {
    my ($class, $c, $files) = @_;

    # 並びは file の path 順で確定させる。表示順 (更新が新しい順) は
    # script/create_data.pl が翻訳イベントの日付で付け直すので、
    # ここでは readdir の列挙順を持ち込まないことだけを守る。
    # mtime で並べていたのをやめたのは、fresh clone では全ファイルの mtime が
    # checkout 時刻に潰れて「更新が新しい順」の意味を失い、同時刻どうしの並びが
    # 環境依存の readdir 順に落ちて生成物が非決定的になるため
    my @mods;
    foreach my $entry (sort { $a->{rel} cmp $b->{rel} } @$files) {
        my ($repository, $raw_file, $distvname) =
            @{$entry}{qw/repository raw rel/};
        my $is_pod;
        my ($row, $package, $dist, $abstract);
        # 読み出しは生バイトの path で行い、構造の解釈は decode 済みの
        # 相対 path で行う
        if ($distvname =~ m{^([^/]+)/(?:.*?/)?([^/]+)\.html$}) {
            $is_pod = 0;
            ($package, $dist) = ($1, $2);
            ($dist, $abstract) = $c->abstract_title_description(scalar slurp($raw_file));
        } elsif ($distvname =~ m{^([^/]+)/(?:.*?/)?([^/]+)\.md$}) {
            $is_pod  = 0;
            ($package, $dist) = ($1, $2);
            ($dist, $abstract) = $c->abstract_title_description_from_md(scalar slurp($raw_file));
        } elsif ($distvname =~ m{^([^/]+)/(?:.*?/)?([^/]+?)\.pod$}) {
            $is_pod  = 1;
            ($package, $dist) = ($1, $2);
        }
        $row = {
                name       => $dist,
                version    => 0,
                package    => $package,
                distvname  => $distvname,
                repository => $repository,
                abstract   => $abstract,
               };

        if ($is_pod) {
            debugf("parsing %s", $distvname);
            my ($name, $desc) = PJP::M::Pod->parse_name_section($raw_file);
            if ($desc) {
                debugf("Japanese Description: %s, %s", $name, $desc);
                $row->{abstract} = $desc;
            }
        }

        push @mods, $row;
    }

    return @mods;
}

1;
