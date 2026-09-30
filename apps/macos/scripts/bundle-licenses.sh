#!/bin/bash
# 本体と依存のライセンス表示をアプリのバンドルへ入れる。
#
# libwebrtc（BSD 3-Clause）も swift-* （Apache-2.0）も、バイナリ配布のときに
# 著作権表示とライセンス全文を添えることを条件にしている。配布物に入っていなければ
# 条件を満たさないため、開発ビルドから同じ形で入れておく（THIRD-PARTY-NOTICES.md）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CHECKOUTS="${BUILD_DIR:-}/../../SourcePackages/checkouts"
DESTINATION="${BUILT_PRODUCTS_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}/Licenses"

rm -rf "$DESTINATION"
mkdir -p "$DESTINATION"

cp "$ROOT/LICENSE" "$DESTINATION/DoppelScreen-LICENSE.txt"
cp "$ROOT/THIRD-PARTY-NOTICES.md" "$DESTINATION/THIRD-PARTY-NOTICES.md"

# 依存のライセンスは SwiftPM のチェックアウトから拾う。名前も版もここが正
if [ -d "$CHECKOUTS" ]; then
  for package in "$CHECKOUTS"/*/; do
    name="$(basename "$package")"
    for candidate in LICENSE.txt LICENSE LICENSE.md NOTICE.txt NOTICE; do
      if [ -f "$package$candidate" ]; then
        cp "$package$candidate" "$DESTINATION/$name-$candidate"
      fi
    done
  done
else
  echo "warning: 依存のチェックアウトが見つかりません（$CHECKOUTS）" >&2
fi

# ホスト UI（Flutter）のエンジンと Dart パッケージのライセンスは、Flutter が
# App.framework に gzip で同梱している（flutter_assets/NOTICES.Z）。読める形で並べる
NOTICES="${BUILT_PRODUCTS_DIR:?}/${FRAMEWORKS_FOLDER_PATH:?}/App.framework/Resources/flutter_assets/NOTICES.Z"
if [ -f "$NOTICES" ]; then
  gunzip -c < "$NOTICES" > "$DESTINATION/Flutter-NOTICES.txt"
else
  echo "warning: ホスト UI のライセンス表示が見つかりません（$NOTICES）" >&2
fi

echo "ライセンス表示を $DESTINATION へ配置しました"
