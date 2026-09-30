# ADR 0002: ホスト UI 層を Flutter で統一する

- **状態**: **採用**
- **決定日**: 2026-09-30
- **関連**: [ADR 0001](0001-host-implementation-stack.md), [SPEC.md](../../SPEC.md) §2.3 `HostUI`, [docs/STACK.md](../STACK.md)

## 決定

**ホストの UI 層（`HostUI` のウィンドウ部分）だけを Flutter で書き、全プラットフォームで 1 実装にする。
キャプチャ・エンコード・WebRTC・LocalServer・証明書・セッション管理（コア）は、これまでどおり各プラットフォームのネイティブ実装のままにする。**

- Flutter は既存のネイティブアプリへの埋め込み（add-to-app 相当）として使う。アプリの骨格（プロセス・メインループ・ウィンドウの持ち主）はネイティブ側に残す
- **Flutter エンジンは常駐させる。** ウィンドウを閉じても破棄しない
- UI ⇄ コアの通信は **Pigeon** に全プラットフォームで揃える
  - Dart → コア: `@HostApi`（操作: 開始・停止・承認・拒否・切断など）
  - コア → Dart: `@FlutterApi`（状態の通知。起動直後だけ `@HostApi` 側の `currentState()` で取りに行く）
  - EventChannel は使わない。Pigeon のイベントチャネルは Swift / Kotlin 専用で、C++ にはないため
- **ネイティブコードを持つ Flutter プラグインは使わない。** QR は `qr_flutter`（純 Dart）、コピーは標準の `Clipboard` を使い、外部の URL やシステム設定を開く処理は Pigeon 経由でネイティブに任せる
- **トレイ / メニューバーのアイコンとメニューはネイティブのまま**にする（Flutter の流儀に合わない。ADR 0001 §3.3）
- 文言は `i18n/*.yaml` から `tools/i18n` の Dart 出力で生成する。ネイティブ側に残る文言（トレイメニューなど）は既存の出力を使う
- iOS の Broadcast Upload Extension には Flutter を持ち込まない（ADR 0001 §4-3 のまま）。Flutter を使うのはコンテナアプリの画面だけ

## ADR 0001 との関係

ADR 0001 が却下したのは「**ホスト全体**を Flutter で共通化する」案であり、本 ADR はそれを覆さない。
0001 の懸念のうち、メディア経路（§3.1）・フレームが Dart に入る危険（§3.4）・遅延のプロファイリング（§3.5）・証明書（§3.6）は、
いずれもコアに関するもので、UI 層だけを Flutter にする本案では該当しない。フレームも SDP も Dart には入らない。

0001 の「再検討の条件」の 1 つ目（M3 で UI の重複が負担になる）は、M3 の時点で満たされた。
macOS（SwiftUI）と Windows（Win32）の UI は、About・トレイの状態表示・実効解像度と品質の表示・状態の色分け・エラー表示などで既に食い違っており、
Windows 側は DPI 非対応・固定座標のレイアウトという土台の弱さも抱えていた。ネイティブのまま仕様書で揃えても、実装が 4 つ残る限り差は再発する。

## 背景となった実測

どちらも「開始 → 8422/8423 で待受 → ヘッドレス Chrome から接続要求 → Flutter の承認ボタン → 配信中 → ビューアに映像」までを通した。

### macOS（Debug、待受前）

| 構成 | .app | 窓あり | 窓を閉じた後 |
| --- | --- | --- | --- |
| 現行 SwiftUI | 52MB | 29MB | 31MB |
| Flutter UI | 91MB（+40MB） | 63MB | 65MB（解放されない） |
| WKWebView（参考） | +0 | 約 +50MB | 約 +35MB |

### Windows 11（Intel Iris Xe、Release、Private の合計）

| 構成 | 開いている間 | 閉じている間 | 再表示 | 配布物の増分 |
| --- | --- | --- | --- | --- |
| 現行 Win32 | 42MB | 42MB | 即時 | — |
| Flutter・常駐 | 170MB | 171MB | 即時 | +27MB |
| Flutter・閉じたら破棄 | 170MB | 147MB | 約 2.2 秒。再作成後は 227MB に膨らむ | +27MB |
| WebView2・常駐（休止 API 込み） | 191MB | 184MB | 即時 | +42KB |
| WebView2・閉じたら破棄 | 195MB | 42MB | 約 0.9 秒 | +42KB |
| 参考: 素の Flutter runner | 141MB | — | — | — |

- Flutter の増分はエンジンそのもので、組み込み方による上乗せはない（素の runner で 141MB）
- Flutter の Dart VM と DLL はエンジンを破棄してもプロセスから抜けない。閉じたら破棄しても 23MB しか戻らず、作り直すとかえって膨らむ。**常駐が妥当**
- 最初のフレームまで: Flutter 約 1.2 秒、WebView2 約 0.6〜0.75 秒

## 採らなかった選択肢

| 案 | 理由 |
| --- | --- |
| **WebView（WebView2 / WKWebView）で Web UI** | 実測では有利な点があった（閉じて破棄すれば 42MB に戻る、UIA で中身が見える、配布物 +42KB、ビューアのツールチェーンを流用できる）。一方で開いている間は Flutter より重く（+154MB・6 プロセス）、休止 API はほぼ効かない。維持者が Flutter の方に流暢であることを重く見て、**維持者の判断で不採用** |
| ネイティブのまま UI 仕様書で揃える | 実装が 4 つ残り、差が再発する |
| ホスト UI を LocalServer（HTTP）で配信する | 承認操作が LAN から届く位置に出てしまい、無人アクセスの防止（SPEC §5.2）が崩れる。UI ⇄ コアはプロセス内に限る |
| Qt Quick / QML | Windows 本体（`/MT`）と Qt の DLL（`/MD`）で CRT が混ざる。iOS での LGPLv3 の扱い、Swift から使う手段の弱さ |
| Slint | Swift / Kotlin のバインディングがなく、既存ウィンドウへの埋め込みが自作になる |
| Compose Multiplatform | デスクトップが JVM 前提 |
| .NET MAUI / Avalonia | .NET ランタイムの同居が要る |
| React Native（Windows / macOS） | ツールチェーンが最も重い |
| wxWidgets | iOS / Android がない |
| Dear ImGui | アクセシビリティがない |
| Tauri | アプリ全体を所有する構造で、既存のプロセスに埋め込めない |
| Sciter / Ultralight | OSS でない |
| GPUI | アプリを所有する構造で既存の HWND / NSView に入れられない。アクセシビリティがない。Rust 専用 |
| Lynx | 構造は合うが、デスクトップ対応が新しく、アクセシビリティとメモリの情報がない |

## 引き受けるもの

- **メモリ**: Windows で +128MB（常駐）、macOS で +34MB。配信中のエンコードに影響しないかは測る
- **配布物**: Windows で +27MB、macOS で +40MB
- **アクセシビリティ**: Windows の UIA クライアントからは `FLUTTERVIEW` の枠しか見えなかった。スクリーンリーダー（ナレーター / NVDA / VoiceOver）で承認・拒否・切断が読み上げられるかは実機で確認する。読めなければ Flutter のセマンティクスを有効化する手段を調べる
- **Windows の埋め込みは公式の add-to-app の対象外**。公開されている C++ の client wrapper（`FlutterViewController`）と Flutter が生成する CMake だけで組み込めたが、Flutter の更新時に壊れうる
- **UI に待機中のアニメーションを置かない**。映している画面の上にホスト UI のウィンドウがあると、その描画も符号化される

## 実装上の要点

- **macOS**: `flutter build macos-framework --no-codesign` の `FlutterMacOS.xcframework` と `App.xcframework` を `project.yml` から埋め込む。署名はアプリ側の埋め込み時に行う
- **Windows**: Flutter が生成する `windows/flutter/CMakeLists.txt` を既存の CMake から `add_subdirectory` で取り込む。runner は使わない。
  UI スレッドは STA にし、`CoIncrementMTAUsage()` で暗黙の MTA を残す（libwebrtc のスレッドが COM を初期化しないまま MF / WinRT を呼ぶため）
- コア側は変更しない。既存の状態のスナップショット + 変化の通知が、そのまま UI ブリッジの境界になる
