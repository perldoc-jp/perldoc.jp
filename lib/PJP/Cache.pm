use strict;
use warnings;
use utf8;

package PJP::Cache;
use Cache::LRU;

# コンテンツはデプロイ単位で不変なため、有効期限なしのオンメモリ LRU で足りる。
# (データ更新 = イメージ再ビルド + 再デプロイ = プロセス入れ替え)
sub new {
    my $class = shift;
    bless {
           cache => Cache::LRU->new(size => 256),
          }, $class;
}

sub get_or_set {
    my ($self, $key, $cb) = @_;

    $key .= rand() if $ENV{DEBUG};

    # 開発環境では data/ を bind mount して make setup-data で作り直すため、
    # 期限も mtime 検査も無いこのキャッシュを効かせると、一度表示したページが
    # プロセスを再起動するまで古いままになる (plackup -r も data/ は見ない)
    return $cb->() if ($ENV{PLACK_ENV} // '') ne 'deployment';

    my $val = $self->{cache}->get($key);
    return $val if defined $val;

    $val = $cb->();
    $self->{cache}->set($key, $val);
    return $val;
}

1;
