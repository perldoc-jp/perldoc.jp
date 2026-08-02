#!/bin/bash
# ビルド済みイメージを Cloud Run 相当の FS 制約 (--read-only + /tmp の tmpfs) で
# 起動し、主要経路の開通を確認する。deploy.yml (デプロイ前の検証) と test.yml
# (PR での runtime ビルド検証) が共用する。
#
# 使い方: script/smoke-test.sh <image>
set -eu

IMAGE=$1

docker run -d --name smoke --read-only --tmpfs /tmp \
  -e PORT=8080 -p 8080:8080 "$IMAGE"
trap 'docker logs smoke' ERR
for _ in $(seq 1 30); do
  curl -fsS -o /dev/null http://127.0.0.1:8080/ && break
  sleep 2
done
curl -fsS http://127.0.0.1:8080/ | grep 'perldoc.jp' > /dev/null
curl -fsS -o /dev/null http://127.0.0.1:8080/docs/perl/perl.pod
curl -fsS http://127.0.0.1:8080/translators | grep '年</h2>' > /dev/null
curl -fsS http://127.0.0.1:8080/static/docs.json | grep 'Acme::Bleach' > /dev/null
# イメージへの static/favicon.ico の取り込み漏れを検出する
curl -fsS -o /dev/null http://127.0.0.1:8080/favicon.ico
# runtime の allowlist COPY の列挙漏れを検出する
# (toc.txt / toc-var.txt はこの 2 ルートでしか読まれない)
curl -fsS -o /dev/null http://127.0.0.1:8080/index/core
curl -fsS -o /dev/null http://127.0.0.1:8080/index/variable
# perlfunc に焼き込まれた組み込み関数リンクを検出する。@REGEXP が空の
# まま HTML を生成すると、リテラル置換分の 9 件程度しか残らない
# (databuild 中の functions.txt の有無に依存し、prove では捕まらない)
links=$(curl -fsS http://127.0.0.1:8080/docs/perl/5.36.0/perlfunc.pod \
  | grep -o 'href="/func/[a-z]*"' | sort -u | wc -l)
echo "perlfunc の /func/ リンク数: $links"
test "$links" -gt 100
docker rm -f smoke
