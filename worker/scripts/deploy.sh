#!/bin/bash
# Worker のデプロイ。デプロイ先モードだけを受け取り、wrangler の argv は
# このスクリプトが組み立てる。
#
#   deploy.sh production                     本番 (wrangler.jsonc の top-level)
#   deploy.sh staging                        staging (named environment)
#   deploy.sh production --dry-run <outdir>  受け入れ検査
#   deploy.sh staging    --dry-run <outdir>  同上
#
# 手順が workflow と手元 (docs/cloud-run.md) に分かれていると、ORIGIN の
# 渡し忘れのような差が無症状で通る。--dry-run を残すのは、受け入れ検査が
# 使う argv と本番が使う argv を同じ 1 本の生成器から出すため。
set -Eeuo pipefail

# 呼び出し元の cwd に npm exec / package.json / wrangler.jsonc の探索を
# 左右させない
worker_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
cd "$worker_dir"

die() {
    printf '%s: %s\n' "${0##*/}" "$*" >&2
    exit 1
}

[ "$#" -ge 1 ] || die 'usage: deploy.sh production|staging [--dry-run <outdir>]'

mode=$1
shift

# production は Cloudflare の一般名称ではなく、このリポジトリで
# wrangler.jsonc の top-level environment を指す名前。
#
# selector は必ず明示する。CLOUDFLARE_ENV があると --env 無しの deploy は
# その環境を選ぶ (実測: CLOUDFLARE_ENV=staging で staging の NOINDEX が付く)。
# --env= を明示すると ambient に勝って top-level になる。
# wrangler.jsonc に environment を足すときはここも同時に触ること
case "$mode" in
    production) env_selector='--env=' ;;
    staging)    env_selector='--env=staging' ;;
    *) die "mode must be 'production' or 'staging' (got: $mode)" ;;
esac

dry_run_args=()
if [ "$#" -gt 0 ]; then
    [ "$1" = '--dry-run' ] || die "unexpected argument: $1"
    [ "$#" -eq 2 ] || die '--dry-run requires exactly one <outdir>'
    outdir=$2

    # このスクリプトは worker root へ cd するので、相対 path を許すと
    # '.' がリポジトリの中へ書き込む。wrangler は outdir を再帰的に作って
    # README.md と bundle を書くので、既存ディレクトリも上書きできる
    case "$outdir" in
        /*) ;;
        *) die "<outdir> must be an absolute path (got: $outdir)" ;;
    esac
    # -e だけでは dangling symlink を見逃す
    [ ! -e "$outdir" ] && [ ! -L "$outdir" ] \
        || die "<outdir> must not exist yet (got: $outdir)"

    dry_run_args=(--dry-run --outdir "$outdir")
fi

# 設定ミスの ORIGIN でデプロイすると、その後の全リクエストが 502 になるまで
# 気づけない。Worker 本体と同じ検証をここでも通し、失敗したら wrangler を
# 絶対に呼ばない
: "${ORIGIN:?ORIGIN is required}"
node "$worker_dir/scripts/assert-origin.mjs" || die 'ORIGIN did not pass validation'

# ORIGIN は平文の --var ではなく Worker の secret として渡す
# (docs/cloud-run.md §7 の分類。dashboard の平文 Variable に値を出さない)。
# --secrets-file は dry-run とも併用でき、offline で動く。
# 一時ファイルは 0600 で作り、EXIT trap で消す (SIGKILL など trap が走らない
# 終了では残り得るため、$TMPDIR 直下の一時名にとどめる)
secrets_file=$(mktemp "${TMPDIR:-/tmp}/perldoc-jp-worker-secrets.XXXXXX")
chmod 600 "$secrets_file"
trap 'rm -f "$secrets_file"' EXIT
printf 'ORIGIN=%s\n' "$ORIGIN" > "$secrets_file"

# 使用状況の送信を止める。子プロセスへ渡すので export する
export WRANGLER_SEND_METRICS=false

# --config を絶対 path で常に渡す。.wrangler/deploy/config.json による設定
# リダイレクトは .gitignore で .wrangler 全体が無視されるため clean tree でも
# 残りうる。
#
# --secrets-file を落とした本番デプロイは wrangler.jsonc の secrets.required に
# より失敗する (dry-run では検査されない)。
#
# npm exec 経由で呼ぶのは、直叩きでは node_modules/.bin が PATH に入らないため。
# --offline はこの step がレジストリに触れない (= 追加のインストールが
# 走らない) ことを保証する。exec しないのは EXIT trap で secrets file を
# 消すため (exec するとこのシェルが消えて trap が走らない)
# dry_run_args の展開は ${arr[@]+...} の形にする。macOS の /bin/bash (3.2) は
# set -u で空配列の "${arr[@]}" を unbound variable と誤検知し、非 dry-run の
# デプロイがここで止まる (bash 4.4 で修正された挙動)
npm exec --offline --no -- wrangler deploy \
    --config "$worker_dir/wrangler.jsonc" \
    "$env_selector" \
    --secrets-file "$secrets_file" \
    ${dry_run_args[@]+"${dry_run_args[@]}"}
