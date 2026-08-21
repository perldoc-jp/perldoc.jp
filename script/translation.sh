#!/bin/bash
# translation リポジトリの取得を 1 本に寄せたスクリプト。
#
#   head              master HEAD の SHA を stdout に 1 行出力する
#   fetch <dir> [ref] <dir> を [ref] (既定 master) の状態にする
#
# pin の規則 (URL・ref・検証) が複数箇所に散ると、PR が deploy と異なる
# translation を検証してゲートの意義が黙って失われる。取得と、取得したものが
# 生成の入力として完全かの検査を、ここに一本化する。
set -Eeuo pipefail

# 対象リポジトリを操作する前に、Git のリポジトリ局所環境変数を消す。
# git -C <dir> は GIT_DIR より弱く、実測で GIT_DIR=<別>/.git git -C target は
# 別リポジトリの HEAD を返す。GIT_INDEX_FILE は index を、
# GIT_OBJECT_DIRECTORY / GIT_ALTERNATE_OBJECT_DIRECTORIES は object store を
# 差し替える。これが無いと、以降の構造検査も状態遷移も入力完全性検査も
# 「引数で指定したリポジトリ」に効いている保証が無い。
# git hook・git rebase -x・git bisect run の中から呼ばれると実際に設定されている
local_env_vars=$(git rev-parse --local-env-vars) || exit 1
# 語分割は意図したもの
# shellcheck disable=SC2086
unset $local_env_vars

# 取得元。テストがネットワーク不要の fixture を組むための seam で、
# 既定は production の URL。信頼できる呼び出し元の入力であって、
# 悪意ある呼び出し元から取得元を守る境界ではない。
# Dockerfile と workflows はこれを設定せず既定を使う
ORIGIN_URL="${TRANSLATION_ORIGIN_URL:-https://github.com/perldoc-jp/translation.git}"

# 一時ファイルはスクリプト全体で 1 つのディレクトリにまとめ、EXIT で片付ける。
# 関数ごとの RETURN trap は local の寿命が切れた後に評価されるため使わない
TMPDIR_SELF=$(mktemp -d "${TMPDIR:-/tmp}/translation.XXXXXX") \
    || { printf 'cannot create a temporary directory\n' >&2; exit 1; }
case "$TMPDIR_SELF" in
    /*) ;;
    *) printf 'temporary directory is not an absolute path\n' >&2; exit 1 ;;
esac
cleanup() {
    rm -rf "$TMPDIR_SELF"
    return 0
}
trap cleanup EXIT

die() {
    printf '%s: %s\n' "${0##*/}" "$*" >&2
    exit 1
}

cmd_head() {
    [ "$#" -eq 0 ] || die 'head takes no arguments'
    # ls-remote の失敗をコマンド置換で握りつぶすと、空の SHA によって
    # checkout が no-op になり pin されないまま進んでしまう。
    # 完全 refname 指定なので出力は最大 1 行
    local sha
    sha=$(git ls-remote "$ORIGIN_URL" refs/heads/master | cut -f1)
    [ -n "$sha" ] || die 'cannot resolve the master HEAD'
    printf '%s\n' "$sha"
}

# [ref] の受理範囲を閉じる。git の fetch 引数は refspec として解釈されるので、
# ':' を含む指定はローカル ref を書き換えられ、wildcard は複数 ref に当たり、
# '-' 始まりは option と紛れる。実利用は master と完全 OID だけ
assert_ref_syntax() {
    local ref=$1
    case "$ref" in
        master) return 0 ;;
    esac
    printf '%s' "$ref" | grep -Eq '^[0-9a-f]{40}([0-9a-f]{24})?$' \
        || die "ref must be 'master' or a full lowercase commit OID (got: $ref)"
}

# 更新前の構造検査。現在どの commit にいるかに依存しない性質だけを見る
assert_structure() {
    local dir=$1 st url sparse

    git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 \
        || die "$dir is not a git repository"

    # 複数 URL や url.<base>.insteadOf による書き換えで、設定値と実際の
    # 取得先が食い違う余地を残さない
    url=$(git -C "$dir" remote get-url --all origin) \
        || die "$dir has no origin remote"
    [ "$url" = "$ORIGIN_URL" ] \
        || die "$dir origin is not the expected URL (got: $url)"

    # shallow では git log が silent に途中で終わる (年次統計・recent・翻訳者が
    # 黙って欠ける)。fetch だけでは full history に戻らない
    [ "$(git -C "$dir" rev-parse --is-shallow-repository)" = 'false' ] \
        || die "$dir is a shallow clone"

    # sparse checkout は core.sparseCheckout だけで判定する。
    # git sparse-checkout list は非 sparse なリポジトリで空ではなく
    # 'fatal: this worktree is not sparse' の終了 128 になる
    sparse=$(git -C "$dir" config --get core.sparseCheckout) || sparse=''
    case "$sparse" in
        ''|false|0) ;;
        *) die "$dir uses sparse checkout" ;;
    esac

    [ -z "$(git -C "$dir" replace -l)" ] || die "$dir has replace refs"

    # linked worktree では .git はファイルで、info/grafts は common dir 側にある
    local grafts
    grafts=$(git -C "$dir" rev-parse --path-format=absolute --git-path info/grafts) \
        || die "cannot resolve the grafts path of $dir"
    [ ! -e "$grafts" ] || die "$dir has a grafts file"

    # dirty なら止める (利用者の未コミット作業を移動前に守る)。
    # test -z "$(git status)" は git 自体が失敗して出力が空でも成功する
    # fail-open なので、取得の成否と空判定を分ける
    st=$(git -C "$dir" status --porcelain=v1 --untracked-files=all) \
        || die "cannot read the status of $dir"
    [ -z "$st" ] || die "$dir has local changes"
}

# target 移動後の入力完全性検査。commit に依存する性質はすべてこちら
assert_input_complete() {
    local dir=$1 target=$2 st
    local entries="$TMPDIR_SELF/entries"
    local index_oids="$TMPDIR_SELF/index-oids"
    local work_oids="$TMPDIR_SELF/work-oids"

    [ "$(git -C "$dir" rev-parse HEAD)" = "$target" ] \
        || die "$dir is not at $target after the move"

    [ -d "$dir/docs" ] || die "$dir has no docs directory"

    # -v と --stage は併用でき、'<tag> <mode> <oid> <stage>\tpath' の 1 行になる。
    # 1 コマンドで index タグの異常も blob 種別の異常もまとめて閉じる:
    #   skip-worktree (S) / assume-unchanged (h) / sparse checkout の cone 外 (S)
    #   gitlink (160000) / symlink (120000) / conflicted entry (stage != 0)
    #
    # symlink を落とすのは、Git が追跡するのはリンク文字列だけなのに
    # File::Find::Rule->file は file 宛ての symlink を対象に含めてリンク先を
    # 読むため。リンク先の変化は status にも生成物の一覧にも出ない
    git -C "$dir" ls-files -v --stage -- docs >"$entries" \
        || die "cannot list the index entries of $dir/docs"
    [ -s "$entries" ] || die "$dir/docs has no tracked entries"
    awk '$1 != "H" || ($2 != "100644" && $2 != "100755") { bad = 1 } END { exit bad }' \
        "$entries" || die "$dir/docs has entries that are not plain tracked files"

    # generator は Git の index ではなく実ファイルシステムを走査するので、
    # ignored な .pod が混ざると黙って入力になる
    st=$(git -C "$dir" status --porcelain=v1 --ignored=matching -- docs) \
        || die "cannot read the docs status of $dir"
    [ -z "$st" ] || die "$dir/docs is not clean"

    # 作業ツリーの生バイト列が index blob と一致すること。clean/smudge filter
    # や core.autocrlf が効くと、Git は clean と判定するのに generator が読む
    # バイト列は blob と違う。--no-filters は属性による変換と改行変換を無視して
    # ファイルの中身そのものをハッシュする
    git -C "$dir" ls-files -s -- docs | awk '{print $2}' >"$index_oids" \
        || die "cannot list the index OIDs of $dir/docs"
    git -C "$dir" ls-files -z -- docs \
        | xargs -0 git -C "$dir" hash-object --no-filters -- >"$work_oids" \
        || die "cannot hash the working tree of $dir/docs"
    cmp -s "$index_oids" "$work_oids" \
        || die "$dir/docs working tree differs from the index blobs"

    # partial clone の実体検査。config は object の実在を証明しない
    # (tree:0 clone の filter 値を blob:none に書き換えるだけで通り抜ける)。
    # commit_events は全履歴の git log --name-status を入力にするので、
    # その走査がネットワーク無しで完走することを直接試す
    GIT_NO_LAZY_FETCH=1 git -C "$dir" \
        log --no-renames --name-status --format= HEAD >/dev/null \
        || die "$dir cannot walk its history offline (incomplete partial clone?)"

    # 移動でリポジトリ全体が dirty になっていないことも見る
    st=$(git -C "$dir" status --porcelain=v1 --untracked-files=all) \
        || die "cannot read the status of $dir"
    [ -z "$st" ] || die "$dir has local changes after the move"
}

cmd_fetch() {
    [ "$#" -ge 1 ] && [ "$#" -le 2 ] || die 'usage: fetch <dir> [ref]'
    local dir=$1 ref=${2:-master}
    assert_ref_syntax "$ref"

    # SKIP_ASSETS_UPDATE の受理範囲。未設定/空/0 は通常更新、正確に 1 なら
    # 既存ディレクトリの更新を skip、その他の非空値はリポジトリを変える前に停止。
    # 現行 update.pl は Perl の truthy 値なら何でも受けるが、README が
    # 文書化しているのは 1 だけなので、そこを明文化する
    case "${SKIP_ASSETS_UPDATE:-}" in
        ''|0) ;;
        1)
            # 守るべき既存の checkout があるときだけ即座に返る。無いときは
            # どのみち clone が要るので、検査つきの通常経路を通す
            if [ -d "$dir" ]; then
                return 0
            fi
            ;;
        *) die "SKIP_ASSETS_UPDATE must be unset, empty, 0 or 1 (got: $SKIP_ASSETS_UPDATE)" ;;
    esac

    local created_by_script=0
    if [ ! -d "$dir" ]; then
        # filter は現行 Dockerfile の clone と同じにする。create_data.pl は
        # 全履歴の git log を要るが blob 本体は要らない。--depth は使わない
        git clone --filter=blob:none "$ORIGIN_URL" "$dir" \
            || die "cannot clone $ORIGIN_URL into $dir"
        created_by_script=1
    fi

    assert_structure "$dir"

    # ref が OID でも fetch は常に master。特定 SHA を直接 fetch できるかは
    # サーバ設定に依存するので当てにしない
    git -C "$dir" fetch --no-tags origin master \
        || die "cannot fetch master from origin in $dir"

    local target type
    if [ "$ref" = 'master' ]; then
        target=$(git -C "$dir" rev-parse --verify 'FETCH_HEAD^{commit}') \
            || die 'cannot resolve the fetched master'
    else
        # rev-parse --verify <oid>^{commit} は annotated tag object も peel する。
        # tag OID をここで通すと移動まで成功して事後条件で落ちるので、
        # object の型そのものを見る
        type=$(git -C "$dir" cat-file -t "$ref" 2>/dev/null) \
            || die "$ref does not exist in $dir"
        [ "$type" = 'commit' ] || die "$ref is a $type, not a commit"
        git -C "$dir" merge-base --is-ancestor "$ref" FETCH_HEAD \
            || die "$ref is not reachable from master"
        target=$ref
    fi

    local head branch
    head=$(git -C "$dir" rev-parse HEAD) || die "cannot resolve HEAD of $dir"
    branch=$(git -C "$dir" symbolic-ref --quiet --short HEAD) || branch=''

    if [ "$head" = "$target" ]; then
        : # 移動不要
    elif [ "$created_by_script" -eq 1 ]; then
        # 自分で今 clone したディレクトリには、守るべきローカル branch も
        # 未コミット作業も無い。ref 既定の master では 1 つ上の分岐に当たるので、
        # detach するのは完全 OID を明示したときだけ
        git -C "$dir" checkout --quiet --detach "$target" \
            || die "cannot check out $target in $dir"
    elif [ "$branch" = 'master' ] && git -C "$dir" merge-base --is-ancestor "$head" "$target"; then
        # merge --ff-only は HEAD が target より先のとき 'Already up to date.' で
        # 終了 0 になり HEAD は動かない。祖先であることを先に確かめる
        git -C "$dir" merge --ff-only "$target" >/dev/null \
            || die "cannot fast-forward $dir to $target"
    else
        die "$dir is not on a clean master that can fast-forward to $target (HEAD=$head branch=${branch:-detached})"
    fi

    assert_input_complete "$dir" "$target"
}

[ "$#" -ge 1 ] || die 'usage: translation.sh head | fetch <dir> [ref]'
subcommand=$1
shift
case "$subcommand" in
    head)  cmd_head  "$@" ;;
    fetch) cmd_fetch "$@" ;;
    *)     die "unknown subcommand: $subcommand" ;;
esac
