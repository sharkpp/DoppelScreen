# ホスト UI（Flutter）

ホストアプリのウィンドウの中身。全 OS で共通の 1 実装で、各 OS のネイティブアプリに埋め込んで使う
（[ADR 0002](../../docs/adr/0002-host-ui-flutter.md)、[docs/STACK.md §2.18](../../docs/STACK.md)）。
単体では起動しない（コアがいないと何も描けない）。

- `pigeons/host.dart` — コアとの境界。直したら `make host-ui-generate`
- `lib/generated/strings.dart` — 文言。`i18n/*.yaml` を直して `make i18n`
- `test/` — ウィジェットテスト。`make host-ui-test`
- `macos/` — `flutter build macos-framework` が要求するので置いているだけ
