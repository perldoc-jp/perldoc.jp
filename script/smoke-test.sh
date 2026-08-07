#!/bin/bash
# ビルド済みイメージを Cloud Run 相当の FS 制約 (--read-only + /tmp の tmpfs) で
# 起動し、主要経路の開通を確認する。deploy.yml (デプロイ前の検証) と test.yml
# (PR での runtime ビルド検証) が共用する。
#
# 使い方: script/smoke-test.sh <image>
#
# pipefail が無いと `curl | grep` の終了コードが grep のものになり、マーカーが
# 届いた後に転送が切れた場合 (curl の 18/56) を検出できない
set -euo pipefail

IMAGE=$1

# コンテナ名は実行ごとに一意にする。固定名だと途中失敗の残骸と名前衝突して
# 再実行が trap 設置前の docker run で死に、元の失敗の診断もできなくなる
NAME=smoke-$$

# 失敗時は診断ログを出し、コンテナは成否によらず必ず消す。bash は trap の
# 中でも set -e が生きていて、途中のコマンド失敗で残りが打ち切られるため、
# docker run 前に死んだ場合 (コンテナ不在) に備えて各コマンドを || true で握る
cleanup() {
  status=$?
  if [ "$status" -ne 0 ]; then
    docker logs "$NAME" || true
  fi
  docker rm -f "$NAME" > /dev/null 2>&1 || true
  exit "$status"
}
trap cleanup EXIT

# ホスト側ポートは固定しない。8080 固定だと docker compose (make up) が
# bind している最中や並行実行と衝突する。127.0.0.1 への bind なので
# テスト中のコンテナが LAN に公開されることもない
docker run -d --name "$NAME" --read-only --tmpfs /tmp \
  -e PORT=8080 -p 127.0.0.1::8080 "$IMAGE"
BASE="http://$(docker port "$NAME" 8080/tcp)"

for _ in $(seq 1 30); do
  curl -fsS -o /dev/null "$BASE/" && break
  sleep 2
done
curl -fsS "$BASE/" | grep 'perldoc.jp' > /dev/null
curl -fsS -o /dev/null "$BASE/docs/perl/perl.pod"
curl -fsS "$BASE/translators" | grep '年</h2>' > /dev/null
curl -fsS "$BASE/static/docs.json" | grep 'Acme::Bleach' > /dev/null
# イメージへの static/favicon.ico の取り込み漏れを検出する
curl -fsS -o /dev/null "$BASE/favicon.ico"
# runtime の allowlist COPY の列挙漏れを検出する
# (toc.txt / toc-var.txt はこの 2 ルートでしか読まれない)
curl -fsS -o /dev/null "$BASE/index/core"
curl -fsS -o /dev/null "$BASE/index/variable"
# 差分表示は、外部コマンドの diff を fork し /tmp に一時ファイルを書く唯一の
# ルート。prove は diffutils が必ず入っている databuild イメージ (slim ではない)
# で走るため、slim の runtime で diff が引けることと、read-only FS + tmpfs の
# /tmp に書けることは、ここでしか確かめられない。
# 版の組は t/endpoints.t と同じものを使う (translation から失われた場合は
# test ステージの prove が先に落ちる)
curl -fsS "$BASE/docs/perl/5.38.0/perl.pod/diff?target=perl%2F5.36.0%2Fperl.pod" \
  | grep "<table class='diff'>" > /dev/null
