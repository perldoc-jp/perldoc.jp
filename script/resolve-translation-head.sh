#!/bin/bash
# translation の master HEAD の SHA を stdout に出す。
#
# deploy (master push) と PR の runtime-test はこの SHA を build-arg に渡して
# translation を pin する。pin の規則 (URL・ref・検証) が二箇所で食い違うと、
# PR が deploy と異なる translation を検証してゲートの意義が黙って失われる
# ため、ここに一本化する。
#
# ls-remote の失敗をコマンド置換で握りつぶすと、空の TRANSLATION_COMMIT に
# よって checkout が no-op になり pin されないまま進んでしまうため、
# 空でないことを明示的に検証する
set -euo pipefail

sha=$(git ls-remote https://github.com/perldoc-jp/translation.git refs/heads/master | cut -f1)
test -n "$sha"
echo "$sha"
