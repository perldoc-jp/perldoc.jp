#!/bin/bash
# perldoc.jp ゾーンの Cloudflare キャッシュをすべて purge する。
#
#   CLOUDFLARE_ZONE_ID=... CLOUDFLARE_CACHE_PURGE_TOKEN=... purge-cache.sh
#
# deploy.yml の purge ジョブが Cloud Run のデプロイの後に呼ぶ。Worker の内側の
# キャッシュ (fetch の cf 設定) は TTL が 24 時間あるので、purge しなければ
# デプロイ後も最大 24 時間、古い応答が配られる (docs/cloud-run.md §10)。
# 外側の Workers Cache はゾーンに属さないため、この purge では消えない。
#
# 手順を workflow と手元で分けないよう、緊急時に手で purge するときもこの
# スクリプトを使う (deploy.sh と同じ方針)。
set -Eeuo pipefail

die() {
    printf '%s: %s\n' "${0##*/}" "$*" >&2
    exit 1
}

[ "$#" -eq 0 ] || die 'usage: purge-cache.sh (takes no arguments)'

: "${CLOUDFLARE_ZONE_ID:?CLOUDFLARE_ZONE_ID is required}"
: "${CLOUDFLARE_CACHE_PURGE_TOKEN:?CLOUDFLARE_CACHE_PURGE_TOKEN is required}"

# ZONE_ID は URL の path に入る。32 桁の 16 進以外を通すと、API の別の
# endpoint を指せてしまう
[[ "$CLOUDFLARE_ZONE_ID" =~ ^[0-9a-f]{32}$ ]] \
    || die 'CLOUDFLARE_ZONE_ID must be 32 lowercase hex characters'

# token は下で curl の設定 (1 行 1 オプション) に埋め込む。改行や引用符を
# 通すと別のオプションを注入できるので、Cloudflare の token が使う文字だけを
# 受け付ける。値そのものはエラーにも出さない
[[ "$CLOUDFLARE_CACHE_PURGE_TOKEN" =~ ^[A-Za-z0-9_-]+$ ]] \
    || die 'CLOUDFLARE_CACHE_PURGE_TOKEN contains unexpected characters'

command -v jq > /dev/null || die 'jq is required'

body_file=$(mktemp "${TMPDIR:-/tmp}/perldoc-jp-purge-response.XXXXXX")
trap 'rm -f "$body_file"' EXIT

# token は argv に載せない (同じホストの他プロセスから ps で読める)。
# Authorization ヘッダーは stdin の設定として渡す。
#
# purge_everything は何度呼んでも結果が同じなので、一時的な失敗は curl の
# --retry に任せる (既定で 408 / 429 / 5xx とタイムアウトが対象)。Free プランの
# レート制限は 5 回/分で、この回数と間隔なら超えない
http_code=$(
    printf 'header = "Authorization: Bearer %s"\n' "$CLOUDFLARE_CACHE_PURGE_TOKEN" |
        curl --silent --show-error \
            --max-time 30 --retry 3 --retry-delay 15 \
            --config - \
            --request POST \
            --header 'Content-Type: application/json' \
            --data '{"purge_everything":true}' \
            --output "$body_file" \
            --write-out '%{http_code}' \
            "https://api.cloudflare.com/client/v4/zones/${CLOUDFLARE_ZONE_ID}/purge_cache"
) || die "curl failed (HTTP ${http_code:-none})"

# HTTP の status と本文の success の両方を見る。失敗を成功として通すと、
# 内側の TTL のあいだ古い応答が残り続ける。
# 本文は成功時には出さない (result.id は ZONE_ID で、公開リポジトリの
# ログに残す必要が無い)。失敗時は API の errors だけを出す
if [ "$http_code" = '200' ] && jq -e '.success == true' "$body_file" > /dev/null 2>&1; then
    echo 'purged the zone cache'
    exit 0
fi

errors=$(jq -c '.errors // empty' "$body_file" 2> /dev/null) || errors=''
die "purge failed: HTTP ${http_code}${errors:+ errors=${errors}}"
