#!/bin/bash
# 署名・notarize 済みの配布物を作る（SPEC.md §6.1 / §10 M2）。
#
# 画面キャプチャ + ローカル HTTP(S) サーバという構成は Gatekeeper でも
# アンチウイルスでも引っかかりやすい（SPEC.md §11-8）。Developer ID 署名と
# notarization は「配ったものがそのまま起動する」ための最低条件になる。
#
# 必要なもの（この 2 つは開発者ごとに用意する。リポジトリには入れない）:
#
#   1. Developer ID Application 証明書がログインキーチェーンにあること
#        security find-identity -v -p codesigning
#   2. notarytool の資格情報プロファイル
#        xcrun notarytool store-credentials doppelscreen \
#          --apple-id <Apple ID> --team-id <TeamID> --password <App 用パスワード>
#
# 使い方:
#   SIGNING_IDENTITY="Developer ID Application: Name (TEAMID)" \
#   NOTARY_PROFILE=doppelscreen \
#   apps/macos/scripts/release.sh
#
# 環境変数:
#   SIGNING_IDENTITY  署名に使う ID（必須）
#   NOTARY_PROFILE    notarytool のプロファイル名（省略すると署名まででやめる）
set -euo pipefail

MACOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$MACOS_DIR/build-release"
PRODUCTS="$BUILD_DIR/Build/Products/Release"
APP="$PRODUCTS/DoppelScreen.app"
OUTPUT="$MACOS_DIR/dist"

: "${SIGNING_IDENTITY:?SIGNING_IDENTITY を指定してください（例: \"Developer ID Application: Name (TEAMID)\"）}"

echo "==> プロジェクトを生成"
(cd "$MACOS_DIR" && xcodegen generate)

echo "==> Release ビルド"
rm -rf "$BUILD_DIR" "$OUTPUT"
xcodebuild -project "$MACOS_DIR/DoppelScreen.xcodeproj" \
  -scheme DoppelScreen \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  -quiet \
  CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
  CODE_SIGN_STYLE=Manual \
  build

# 内側から署名する。`--deep` は使わない（入れ子の署名要件を潰してしまい、
# Apple も非推奨にしている）。hardened runtime と secure timestamp は notarization の必須条件
echo "==> 署名"
find "$APP/Contents/Frameworks" -name "*.framework" -maxdepth 1 -print0 2>/dev/null |
  while IFS= read -r -d '' framework; do
    codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$framework"
  done
codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

mkdir -p "$OUTPUT"
VERSION="$(defaults read "$APP/Contents/Info" CFBundleShortVersionString)"
ARCHIVE="$OUTPUT/DoppelScreen-$VERSION.zip"

# notarization に渡すのは ditto で作った zip。`zip` コマンドは拡張属性を落として署名を壊す
echo "==> 圧縮"
ditto -c -k --keepParent "$APP" "$ARCHIVE"

if [ -z "${NOTARY_PROFILE:-}" ]; then
  echo
  echo "NOTARY_PROFILE が未指定のため、notarization は行いません。"
  echo "署名済みの成果物: $ARCHIVE"
  exit 0
fi

echo "==> notarization（数分かかります）"
xcrun notarytool submit "$ARCHIVE" --keychain-profile "$NOTARY_PROFILE" --wait

# staple するのは .app。ネットワークが無い環境でも Gatekeeper が検証できるようになる
echo "==> staple"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

rm -f "$ARCHIVE"
ditto -c -k --keepParent "$APP" "$ARCHIVE"

echo
echo "配布物: $ARCHIVE"
spctl --assess --type execute --verbose=2 "$APP"
