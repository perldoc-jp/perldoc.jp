use strict;
use warnings;
use utf8;

# 計算コストの高い diff 結果のキャッシュ。
# 現在の実装は何も保存しない NOP で、重い diff は毎回計算し直す。
# 将来的に GCS や Cloudflare R2 など外部ストレージへの保存を
# このインターフェースの実装として追加する想定。
package PJP::HeavyDiffCache;

sub new {
    my $class = shift;
    bless {}, $class;
}

# 保存済みの diff 計算結果を返す。
# 見つかれば +{ is_cached => bool, diff => $diff } を、無ければ undef を返す。
# is_cached が偽の場合は「タイムアウトした組み合わせ」の記録を意味する。
sub get {
    my ($self, $origin, $target) = @_;
    return undef;
}

# diff 計算結果を保存する。$diff が undef の場合はタイムアウトの記録を意味する。
sub set {
    my ($self, $origin, $target, $diff) = @_;
    return;
}

1;
