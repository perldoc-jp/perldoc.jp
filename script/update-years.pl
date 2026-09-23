#!/usr/bin/env perl

# data/years.pl だけを translation の git 履歴から再導出して書き戻す。
# .github/workflows/deploy.yml の years ジョブが、イメージをビルドする前に実行する。
#
# 使い方: perl script/update-years.pl [対象年]
#
# PJP::M::YearData->build は対象年より前を seed (既存の data/years.pl) から
# そのまま引き継ぎ、対象年以降だけをイベントから再構築する。対象年は既定で
# 「translation の最新イベントの前年」なので、この書き戻しが無いと、ある年が
# 再導出の窓から外れた時点でその年の統計がシードのコミット時点で凍結される。
# 年をまたぐ前に一度実行されていれば足りるが、デプロイのたびに走らせておけば
# コミット済みの years.pl とデプロイされるイメージの中身が構造的に一致する。
#
# 対象年を明示指定してよいのは 2023 年以降だけ (docs/cloud-run.md の「運用」)。
# 2022 年以前は CVS 期の別実装が書いた記録で、現在の git 履歴からは再現できない。
#
# 生成の各段と不変条件は script/create_data.pl が所有している。ここはその
# create_year_data だけを呼ぶ薄いラッパで、導出のロジックは持たない
# (t/CreateData.t が各段を直接呼ぶのと同じ require の作法)。
# docs.json と目次は DB を要するためここでは作らない。それらはイメージビルドの
# databuild ステージが create_data.pl 全体を通して作る

use strict;
use warnings;

use lib qw(./lib);

require './script/create_data.pl';

my $pjp = PJP->bootstrap;

my $events = PJP::M::Repository->commit_events($pjp);

# イベントが 1 件も無いのは translation checkout の異常。空の years.pl を
# 黙って書き戻すと、以降のビルドがそれをシードにしてしまうので必ず止める
# (create_data.pl の main が同じ検査をしている)
die "no translation events found\n" unless @$events;

create_year_data($events, $ARGV[0]);
