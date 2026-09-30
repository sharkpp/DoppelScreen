#!/bin/bash
# ホスト UI（apps/host_ui、Flutter）を xcframework にし、アプリから埋め込めるようにする
# （docs/adr/0002-host-ui-flutter.md）。
#
# Xcode は xcframework の有無をビルドの計画時に見るため、ビルドフェーズでは作れない。
# xcodebuild の前に呼ぶ（Makefile と release.sh）。
#
# 開発ビルドでも Release（AOT）の framework を使う。Debug の framework は JIT で、
# 単体で起動すると遅く、UI の見た目の確認には要らない。
set -euo pipefail

export PATH="/opt/flutter/bin:$HOME/flutter/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOST_UI="$ROOT/apps/host_ui"
OUTPUT="$ROOT/apps/macos/build/HostUI"
STAMP="$OUTPUT/Release/App.xcframework"

if ! command -v flutter >/dev/null 2>&1; then
  echo "error: flutter が見つかりません。Flutter SDK を入れてください" >&2
  exit 1
fi

# Dart 側が変わっていなければ作り直さない（1 回に数十秒かかる）
if [ -d "$STAMP" ] && [ -z "$(find "$HOST_UI/lib" "$HOST_UI/pubspec.yaml" "$HOST_UI/pubspec.lock" -newer "$STAMP" -print -quit)" ]; then
  echo "ホスト UI は最新です"
  exit 0
fi

cd "$HOST_UI"
flutter pub get --enforce-lockfile
# 署名はアプリへ埋め込むときに Xcode が行う
flutter build macos-framework --release --no-debug --no-profile --no-codesign --output "$OUTPUT"
touch "$STAMP"
