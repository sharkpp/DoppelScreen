#!/bin/bash
# ビューア（apps/web）をビルドし、単一 HTML をアプリのバンドルへ入れる。
# ホスト側はこの 1 ファイルしか知らない（docs/STACK.md §6.1）。
set -euo pipefail

# Xcode のビルドフェーズは PATH が絞られており、Homebrew の node が見えない
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

WEB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../web" && pwd)"

if ! command -v npm >/dev/null 2>&1; then
  echo "error: npm が見つかりません。Node.js を入れてください" >&2
  exit 1
fi

if [ ! -d "$WEB_DIR/node_modules" ]; then
  npm --prefix "$WEB_DIR" ci
fi

npm --prefix "$WEB_DIR" run build

DESTINATION="${BUILT_PRODUCTS_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}"
mkdir -p "$DESTINATION"
cp "$WEB_DIR/dist/index.html" "$DESTINATION/viewer.html"
echo "viewer.html を $DESTINATION へ配置しました"
