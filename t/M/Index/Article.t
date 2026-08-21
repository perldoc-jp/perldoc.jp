use v5.38;
use utf8;
use Test2::V0;

use Encode ();
use File::Path ();
use File::Temp qw/tempdir/;
use PJP;
use PJP::M::Index::Article;
use PJP::Util ();

my $context = PJP->bootstrap;

# assets_dir の祖先にも 'assets' という component を置く。文字列置換で
# assets/ より前を削る方式だと、ここで repository 名が 1 つずれる
sub build_assets {
    my $root   = tempdir(CLEANUP => 1);
    my $assets = "$root/assets/work/assets";
    my $base   = "$assets/translation/docs/articles";
    File::Path::make_path("$base/Sample");
    return ($assets, $base);
}

sub write_bytes {
    my ($path, $body) = @_;
    File::Path::make_path(File::Basename::dirname($path));
    open my $fh, '>:raw', $path or die "$path: $!";
    print {$fh} $body;
    close $fh;
}

subtest '祖先に assets/ があっても repository と distvname がずれない' => sub {
    my ($assets, $base) = build_assets();
    write_bytes(Encode::encode_utf8("$base/Sample/日本語.md"),
                Encode::encode_utf8("# 日本語のタイトル\n\n説明文\n\n# 次の節\n"));

    local $context->config->{assets_dir} = $assets;
    my @out = PJP::M::Index::Article->generate($context);

    is scalar(@out), 1, '1 件だけ拾う';
    is $out[0]{repository}, 'translation',
        '祖先の assets/ や work/ を拾わない';
    is $out[0]{distvname}, 'Sample/日本語.md',
        'distvname は articles/ からの相対 path を decode したもの';
};

subtest '読み出しには readdir の生バイトの path を渡す' => sub {
    my ($assets, $base) = build_assets();
    my $raw = Encode::encode_utf8("$base/Sample/日本語.md");
    write_bytes($raw, Encode::encode_utf8("# タイトル\n\n本文\n\n# 次の節\n"));

    my @seen;
    no warnings qw/redefine once/;
    my $orig = \&PJP::Util::slurp;
    local *PJP::Util::slurp = sub { push @seen, $_[0]; $orig->(@_) };
    local *PJP::M::Index::Article::slurp = sub { push @seen, $_[0]; $orig->(@_) };

    local $context->config->{assets_dir} = $assets;
    PJP::M::Index::Article->generate($context);

    is scalar(@seen), 1, 'slurp が 1 回呼ばれる';
    ok !utf8::is_utf8($seen[0]), '渡された path は decode されていない';
    is $seen[0], $raw, 'readdir が返した生バイトと同一';
};

subtest 'assets_dir の外は止める' => sub {
    my $root = tempdir(CLEANUP => 1);
    File::Path::make_path("$root/elsewhere/translation/docs/articles/Sample");
    local $context->config->{assets_dir} = "$root/assets";
    File::Path::make_path("$root/assets");

    like dies {
        PJP::M::Index::Article->_get_files(
            $context, "$root/elsewhere/translation/docs/articles")
    }, qr/outside of assets_dir/, 'assets_dir の外の base は拒否する';
};

done_testing;
