# DOPPEL SCREEN

PC もしくはモバイル端末の画面を、同一ネットワーク上の別端末のブラウザに**低遅延で複製表示**するソフトウェアです。

ワイヤレスのサブモニタではなく、ワイヤレスの**複製モニタ**です。

# 機能

- ホストが使用中のディスプレイをリアルタイムに複製し、**ブラウザだけ**で表示する（専用ビューアアプリは不要）
- glass-to-glass 60ms 以下を目標とした低遅延設計
- WebRTC による LAN 内の直接接続。**クラウドサービス・アカウント・インターネット接続を必要としない**
- QR コードを読むだけで接続。ホスト側の承認が必須で、無人アクセスはできない
- 表示端末のサイズに合わせた解像度追従（文字を鮮明に保つ）
- 配信ホストは macOS / Windows / Android / iOS で動作

転送専用です。ブラウザ側からの遠隔操作、音声転送、クリップボード同期は行いません。

# ドキュメント

- 設計仕様: [SPEC.md](SPEC.md) — 何を作るか
- 技術スタック: [docs/STACK.md](docs/STACK.md) — 何で、どう作るか

# 開発

macOS / Windows ホスト + Web ビューアを実装しています。

ホストのウィンドウの中身は Flutter で書いています（[ADR 0002](docs/adr/0002-host-ui-flutter.md)）。
macOS のビルドには Xcode・XcodeGen・Node.js に加えて **Flutter SDK（3.47 以降）** が要ります。
Windows も同じく Flutter SDK が要ります（手順は [apps/windows/README.md](apps/windows/README.md)）。

```sh
make macos-dev-certificate   # 初回のみ。画面収録の許可がリビルドで外れないようにする
make macos-run               # ホストアプリをビルドして起動する
make e2e                     # ホストを起動し、実ブラウザから繋いで映像が出るまでを確認する
```

`make macos-run` で起動して「配信を開始」を押すと、画面ごとの QR と URL が出ます。
手元の端末のカメラで QR を読み、**ホスト側で「承認」を押す**と画面が映ります。
アプリはメニューバーに常駐します（Dock アイコンは持ちません）。

| コマンド | 内容 |
| --- | --- |
| `make macos-run` | ホストアプリをビルドして起動 |
| `make macos-test` | ホスト側の単体テスト（ペアリング・プロトコル・プリセット） |
| `make web-test` | ビューアの単体テスト |
| `make host-ui-test` | ホスト UI（Flutter）のウィジェットテスト |
| `make host-ui-generate` | ホスト UI とコアの境界（`apps/host_ui/pigeons/host.dart`）から各言語の型を生成 |
| `make e2e` | ホスト + 実ブラウザの通し確認（遅延の内訳も記録する） |
| `make i18n` | 言語定義（`i18n/*.yaml`）を各プラットフォームの形式へ変換 |
| `make icon` | アイコンの原本（`assets/icon/*.svg`）を各 OS のサイズへ書き出す |
| `make macos-selftest` | UI なしでキャプチャの健全性を確認 |
| `make macos-serve` | UI なしで配信を立ち上げ、接続先を表示して待つ |
| `make latency-clock` | glass-to-glass 実測用のミリ秒カウンタを表示 |
| `make macos-release` | 署名・notarize 済みの配布物を作る（証明書が要る） |
| `make macos-reset-permission` | 画面収録の許可をリセット |
| `make windows-build` | Windows x64 ホストを Release ビルド |
| `make windows-test` | Windows側の単体テスト |
| `make windows-run` | Windowsホストをビルドして起動 |

Windows 11 での依存準備とビルド手順は [apps/windows/README.md](apps/windows/README.md) を参照してください。

文言を変えるときは `i18n/ja.yaml` / `i18n/en.yaml` を直して `make i18n` を実行してください
（[docs/STACK.md §6.2](docs/STACK.md)）。アイコンは `assets/icon/doppelscreen.svg` が原本で、
`make icon` が各 OS のサイズを書き出します（[docs/STACK.md §6.3](docs/STACK.md)）。

# 状態

macOS版は M2（実用化）まで実装済みです。Windows版にも QR ペアリングとホスト承認、画面ごとの配信、
解像度追従、品質プリセット、自動再接続、日本語／英語の切り替えを実装しました。
Windows 11 実機でのビルド・配信・遅延検証は残っています。
配布物の署名・notarization は手順とスクリプトを用意した段階で、実行には Developer ID 証明書が要ります。

遅延（M1）は **glass-to-glass の目標 60ms に未達**で、直近の実測は中央値 67ms です
（Wi-Fi・[docs/latency-measurements.md](docs/latency-measurements.md)）。有線での測り直しと
内訳の取得が次の作業です。
