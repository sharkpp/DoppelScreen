# サードパーティのライセンス表示

DoppelScreen 本体は [MIT License](LICENSE) で配布します。
配布物（macOS の `.app`、Windows の `.exe`、およびビューアの HTML）には以下のソフトウェアが含まれます。
**いずれも著作権表示とライセンス全文の同梱を条件とするため、リリース時は本ファイルを配布物に含めてください。**

## ホストアプリ（macOS）に含まれるもの

| ソフトウェア | ライセンス | 含まれ方 |
| --- | --- | --- |
| [libwebrtc](https://webrtc.googlesource.com/src/)（[stasel/WebRTC](https://github.com/stasel/WebRTC) のビルド済み xcframework M151） | BSD 3-Clause | `WebRTC.framework` として同梱 |
| [swift-nio](https://github.com/apple/swift-nio) | Apache-2.0 | 静的リンク |
| [swift-nio-transport-services](https://github.com/apple/swift-nio-transport-services) | Apache-2.0 | 静的リンク |
| [swift-certificates](https://github.com/apple/swift-certificates) | Apache-2.0 | 静的リンク |
| [swift-asn1](https://github.com/apple/swift-asn1) | Apache-2.0 | 上記の依存として静的リンク |
| [swift-crypto](https://github.com/apple/swift-crypto) | Apache-2.0 | 上記の依存として静的リンク |
| [swift-atomics](https://github.com/apple/swift-atomics) | Apache-2.0 | 上記の依存として静的リンク |
| [swift-collections](https://github.com/apple/swift-collections) | Apache-2.0 | 上記の依存として静的リンク |
| [swift-system](https://github.com/apple/swift-system) | Apache-2.0 | 上記の依存として静的リンク |
| [Flutter](https://github.com/flutter/flutter)（エンジンとフレームワーク。ホスト UI、[ADR 0002](docs/adr/0002-host-ui-flutter.md)） | BSD 3-Clause ほか（エンジンが内包する第三者コードを含む） | `FlutterMacOS.framework` として同梱 |
| [Dart](https://github.com/dart-lang/sdk)（ランタイム） | BSD 3-Clause | `App.framework` に AOT で同梱 |
| [qr_flutter](https://github.com/theyakka/qr.flutter) / [qr](https://github.com/kevmoo/qr.dart) | BSD 3-Clause | `App.framework` に AOT で同梱 |

Flutter のエンジンと Dart パッケージのライセンス全文は、Flutter がビルド時に集めて
`App.framework` に入れている（`flutter_assets/NOTICES.Z`）。ビルドフェーズでこれを展開し、
`Contents/Resources/Licenses/Flutter-NOTICES.txt` として並べている。
[pigeon](https://pub.dev/packages/pigeon) と flutter_lints / flutter_test はコード生成・検査・テストだけで使い、配布物には含まれない。

## ホストアプリ（Windows）に含まれるもの

| ソフトウェア | ライセンス | 含まれ方 |
| --- | --- | --- |
| [libwebrtc](https://webrtc.googlesource.com/src/)（shiguredo/webrtc-build M152） | BSD 3-Clauseほか | `webrtc.lib` を静的リンク |
| [Boost.Asio / Boost.Beast](https://www.boost.org/) | Boost Software License 1.0 | 静的リンク |
| [OpenSSL](https://www.openssl.org/) | Apache-2.0 | 静的リンク |
| [libqrencode](https://github.com/fukuchi/libqrencode) | LGPL-2.1-or-later | 静的リンク |
| [nlohmann/json](https://github.com/nlohmann/json) | MIT | ヘッダをコンパイル時に取り込み |

Catch2 はWindows単体テストだけで使い、配布物には含めません。Windows配布時は本ファイルに加え、
各ライブラリおよびlibwebrtcが内包する第三者コードのライセンス全文を同梱してください。
libqrencodeを静的リンクする配布物については、LGPLが要求する再リンク手段（対応するオブジェクト
ファイル等）も提供する必要があります。

## ビューア（HTML）に含まれるもの

ビューアの配布物には**実行時依存が含まれません**（Vite でバンドルした自前のコードのみ）。
以下はビルド時・検証時にだけ使います。配布物に混ざらないため表示義務は生じません。

| ソフトウェア | ライセンス | 用途 |
| --- | --- | --- |
| [vite](https://github.com/vitejs/vite) / [vite-plugin-singlefile](https://github.com/richardtallent/vite-plugin-singlefile) / [vitest](https://github.com/vitest-dev/vitest) | MIT | ビルド・単体テスト |
| [TypeScript](https://github.com/microsoft/TypeScript) / [Playwright](https://github.com/microsoft/playwright) | Apache-2.0 | 型検査・E2E |
| [qrcode](https://github.com/soldair/node-qrcode) / [zxing-wasm](https://github.com/Sec-ant/zxing-wasm) | MIT | glass-to-glass 実測（`apps/web/latency`） |
| [yaml](https://github.com/eemeli/yaml) | ISC | 言語定義の変換ツール（`tools/i18n`） |

---

## 検討した結果と、残っている論点

### MIT で問題ないもの

- **BSD 3-Clause（libwebrtc）と Apache-2.0（swift-*）は MIT と両立する。**
  いずれも「本体を MIT にすること」を妨げない。求められるのは著作権表示・ライセンス全文・
  （Apache-2.0 なら）NOTICE の保持だけで、本ファイルと配布物への同梱で満たせる。
  なお**これらの依存が MIT になるわけではない** — 各ライブラリは元のライセンスのままである。
- **Apache-2.0 の特許条項は MIT 側へ伝播しない。** 依存として利用しているだけで、
  DoppelScreen 自身のコードに Apache-2.0 の条件は乗らない。

### 指摘：MIT とは別軸で残るリスク

1. **H.264 / AVC の特許ライセンス（Via LA、旧 MPEG LA）。**
   OSS ライセンスとは無関係に発生しうる、本プロジェクトで**唯一実害のありうる論点**。
   SPEC.md §2.5 のとおりコーデックは H.264 で確定しており、これは変更しない。

   実装面では、macOS ホストのエンコードは OS の VideoToolbox が行い（`H264EncoderFactory`）、
   ビューア側のデコードもブラウザ／OS が行う。**DoppelScreen 自身は H.264 の符号化器・
   復号器を実装しておらず、配布もしていない。** OS に含まれる実装のライセンスは
   Apple / ブラウザベンダ側で処理されている。したがって現状の配布形態でのリスクは低い。

   ただし次の場合は状況が変わるため、その時点で改めて確認すること。
   - libwebrtc のビルドに **OpenH264 などのソフトウェアエンコーダを含める**場合
     （現在の stasel/WebRTC の Apple 向けビルドは VideoToolbox を使い、含めていない）
   - Windows / Android ホストで、**OS 外の H.264 実装を同梱する**場合
   - 商用販売する場合（無償配布と有償配布で Via LA の扱いが異なる）

2. **配布物へのライセンス同梱がまだ実装されていない。**
   `.app` の中に本ファイルと各ライブラリの LICENSE を入れる必要がある。
   ビルドフェーズで `Contents/Resources/` へコピーする形にすること。
   → M2 の署名・notarize と同時に片付ける（[docs/STACK.md §2.14](docs/STACK.md)）。

3. **"DoppelScreen" という名称は MIT の対象外。**
   MIT が許諾するのは著作権であって商標ではない。フォークが同名で配布することを
   ライセンス上は止められない。名称を守りたい場合は商標登録か、README での明記が要る。
   現時点では実害がないため**何もしない**という判断にしている。

4. **libwebrtc は自身も第三者コードを含む。**
   同梱している `WebRTC.framework` は BSD 3-Clause の本体に加え、上流の
   `LICENSE` / `AUTHORS` / `PATENTS` が対象になる。バイナリ配布の際は
   [上流の LICENSE](https://webrtc.googlesource.com/src/+/refs/heads/main/LICENSE) を
   そのまま同梱すること。
