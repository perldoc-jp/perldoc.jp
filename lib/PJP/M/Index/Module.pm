use strict;
use warnings;
use utf8;
use 5.10.0;

# 目次データは script/create_data.pl がビルド時に data/index-module.pl へ生成する

package PJP::M::Index::Module;
use CPAN::DistnameInfo;
use Log::Minimal;
use File::Find::Rule;
use version;
use autodie;
use PJP::M::Pod;
use PJP::M::Repository ();

sub generate {
    my ($class, $c) = @_;

    # 情報をかきあつめる
    my @mods;
    for my $base (map { File::Spec->catdir( $c->assets_dir(), $_) } qw(
        translation/docs/modules/
    )) {
        push @mods, $class->_generate($c, $base);
    }

    # モジュールを中心に GROUP 化する
    my %module2versions;
    for (@mods) {
        push @{$module2versions{$_->{name}}}, $_;
    }
    for my $module ( keys %module2versions ) {
        # 版が同値になる組 (解析できない版どうしを含む) の並びを readdir の
        # 列挙順に委ねると、versions の順序も先頭から採る abstract も環境に
        # 依存するので、distvname で締めて全順序にする
        $module2versions{$module} = [
            map            { $_->[0] }
              reverse sort { $a->[1] <=> $b->[1] || $a->[0]{distvname} cmp $b->[0]{distvname} }
              map {
                [ $_, eval { version->new( $_->{version} ) } || 0 ]
              } @{ $module2versions{$module} }
        ];
    }

    my @sorted = (
        map {
            +{
                name     => $_,
                abstract => $module2versions{$_}->[0]->{abstract},
                repository => $module2versions{$_}->[0]->{repository},
                latest_version => $module2versions{$_}->[0]->{latest_version},
                versions => $module2versions{$_}
              }
          }
          sort { $a cmp $b } keys %module2versions
    );
    return @sorted;
}

sub _generate {
    my ($class, $c, $base) = @_;

    my $repository = PJP::M::Repository::repository_of($c, $base);

    my @mods;
    opendir(my $dh, $base);
    while (defined(my $e = readdir $dh)) {
        next if $e =~ /^\./;
        next if $e =~ /^CVS$/;

        my ($dist, $version) = CPAN::DistnameInfo::distname_info($e);
        my $row = {distvname => $e, name => $dist, version => $version};

        # ファイル名のいちばん短い pod ファイルが代表格といえる。
        # 同じ長さの候補を持つ dist が実在するので、path で締めて
        # 代表 (= 一覧に出る abstract) を環境に依存させない
        my ($pod_file) = sort { length($a) <=> length($b) || $a cmp $b }
            File::Find::Rule->file()
                            ->name('*.pod')
                            ->in("$base/$e");

        # pod file が一個もないものは表示しない(具体的には CPANPLUS)
        next unless $pod_file;

        debugf("parsing %s", $pod_file);
        my ($name, $desc) = PJP::M::Pod->parse_name_section($pod_file);
        if ($desc) {
            debugf("Japanese Description: %s, %s", $name, $desc);
            $row->{abstract} = $desc;
        }
        else {
            $row->{abstract} = undef;
        }

        $row->{repository} = $repository;

        push @mods, $row;
    }
    return @mods;
}

1;

