# 技術スタックと実装方法

[SPEC.md](../SPEC.md) が「何を作るか」、本ドキュメントが「何で、どう作るか」を扱う。

> **未確定**: ホストを 4 プラットフォームすべてネイティブ実装するか、大部分を Dart/Flutter で共通化するかを検討中。[ADR 0001](adr/0001-host-implementation-stack.md) を参照。本ドキュメントはネイティブ案を記述したものであり、ADR 0001 の結論次第で macOS / Windows / Android の節は差し替わる。**iOS Broadcast Extension が完全ネイティブであることと、ビューアが TypeScript であることはどちらの案でも変わらない。**

---

## 0. サマリ

| | macOS | Windows | Android | iOS | Web ビューア |
| --- | --- | --- | --- | --- | --- |
| 言語 | Swift | C++/WinRT | Kotlin | Swift | TypeScript |
| UI | SwiftUI (`MenuBarExtra`) | WinUI 3 | Jetpack Compose | SwiftUI | 素の DOM |
| キャプチャ | ScreenCaptureKit | Windows.Graphics.Capture | MediaProjection | ReplayKit Extension | — |
| WebRTC | `stasel/WebRTC` (SPM) | shiguredo/webrtc-build | `io.github.webrtc-sdk:android` | `stasel/WebRTC` | ブラウザ内蔵 |
| HTTP/WS | SwiftNIO | Boost.Beast | Ktor (CIO) | SwiftNIO | — |
| 証明書生成 | swift-certificates | OpenSSL | ktor-network-tls-certificates | swift-certificates | — |
| ビルド | Xcode / SPM | CMake + vcpkg | Gradle | Xcode / SPM | Vite |

---

## 1. Web ビューア（`apps/web`）

### 1.1 構成

```
Vite + TypeScript + vite-plugin-singlefile
```

- **フレームワークを使わない。** 映像面 + オーバーレイ + 設定シートのみ。
- **`vite-plugin-singlefile` でビルド成果物を単一 HTML に落とす。** JS も CSS も 1 ファイルにインライン化されるため、`LocalServer` 側は「1 つのファイルを返すだけ」になり、静的ファイル配信のルーティング・MIME 判定・キャッシュ制御がすべて不要になる。ホスト実装が 4 プラットフォーム分あることを考えると、この単純化の効果は大きい。
- テストは Vitest。プロトコルのエンコード／デコードと解像度追従のロジックを純粋関数として切り出し、ブラウザなしでテストする。

### 1.2 実装の要点

```ts
// WebSocket のスキームは必ず location から導出する（HTTPS ページから ws: は混在コンテンツでブロックされる）
const wsUrl = `${location.protocol === "https:" ? "wss:" : "ws:"}//${location.host}/signal`;

// トークンは URL fragment。サーバのアクセスログにもリファラにも乗らない
const token = location.hash.slice(1);

// 低遅延化の要（SPEC.md §3.2）。ジッタバッファを捨てる
pc.ontrack = (e) => {
  const r = e.receiver as RTCRtpReceiver & { jitterBufferTarget?: number; playoutDelayHint?: number };
  if ("jitterBufferTarget" in r) r.jitterBufferTarget = 0;
  else if ("playoutDelayHint" in r) r.playoutDelayHint = 0;   // 旧 Chrome 系
  video.srcObject = e.streams[0];
};
```

- 自己診断（SPEC.md §5.3）は `typeof RTCPeerConnection === "undefined"` の判定と、接続確立の 5 秒タイムアウトの 2 段構え。
- 遅延オーバーレイは `pc.getStats()` の `jitterBufferDelay` / `totalDecodeTime` / `framesDropped` / RTT と、`video.requestVideoFrameCallback()` の `expectedDisplayTime` から作る。
- ズームは CSS `transform` を使うが、**ズーム倍率 1.0 のときは `transform` を DOM から完全に外す**。合成レイヤが増えると表示遅延が乗る。

### 1.3 開発ループ

ホストアプリを毎回ビルドし直さずにビューアを触れるようにする。

- 開発時: `vite dev`（:5173）で開き、ホストの WS URL をクエリパラメータで渡す（`?host=192.168.1.10:8422`）。
- 本番: `vite build` → 単一 HTML をホストアプリのバンドルへコピー。

---

## 2. macOS ホスト（`apps/macos`）

### 2.1 依存

| 用途 | パッケージ | 備考 |
| --- | --- | --- |
| WebRTC | [`stasel/WebRTC`](https://github.com/stasel/WebRTC) (SPM) | libwebrtc のビルド済み xcframework。iOS/macOS 対応 |
| HTTP + WebSocket | `apple/swift-nio`（`NIOHTTP1` + `NIOWebSocket`） | HTTP と WS アップグレードを 1 ポートで扱える |
| TLS | `apple/swift-nio-transport-services`（`NIOTSListenerBootstrap`） | Network.framework 経由でシステム TLS を使う。BoringSSL を抱え込まない |
| 自己署名証明書 | `apple/swift-certificates` + `apple/swift-crypto` | SAN 付き X.509 をコードで生成できる |
| QR | Core Image `CIQRCodeGenerator` | 依存追加なし |

- デプロイメントターゲットは **macOS 14+**。ScreenCaptureKit の新しい API（`SCContentSharingPicker` 等）と Swift の並行性を素直に使える。
- 依存はすべて SPM。CocoaPods / Carthage は使わない。

### 2.2 キャプチャ → WebRTC の接続部

ここが macOS ホストの心臓部。**CPU 側でピクセルをコピーしない**ことが要件。

```swift
// SCStreamOutput で受けた CMSampleBuffer をそのまま libwebrtc に渡す
func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
    guard type == .screen,
          let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
          let statusRaw = attachments.first?[.status] as? Int,
          SCFrameStatus(rawValue: statusRaw) == .complete,          // .idle は破棄（SPEC.md §4.3）
          let pixelBuffer = CMSampleBufferGetImageBuffer(sb)
    else { return }

    let frame = RTCVideoFrame(
        buffer: RTCCVPixelBuffer(pixelBuffer: pixelBuffer),          // ラップのみ。コピーしない
        rotation: ._0,
        timeStampNs: Int64(CMSampleBufferGetPresentationTimeStamp(sb).seconds * 1_000_000_000)
    )
    videoSource.capturer(capturer, didCapture: frame)
}
```

`SCStreamConfiguration` の要点:

| プロパティ | 値 | 理由 |
| --- | --- | --- |
| `pixelFormat` | `kCVPixelFormatType_420YpCbCr8BiPlanarFullRange` | VideoToolbox がそのまま食える |
| `minimumFrameInterval` | プリセットの上限 fps | **下限ではなく上限**。SCK は変化時に配るので、これで待たされない（SPEC.md §4.2） |
| `queueDepth` | 3–5 | 大きすぎるとフレームが溜まって遅延になる |
| `showsCursor` | `true` | 焼き込み。操作しないので別送不要 |
| `width` / `height` | ビューアの `viewport` に追従 | SPEC.md §7.1 |

### 2.3 エンコーダ設定について

libwebrtc の VideoToolbox H.264 エンコーダは、**内部で `kVTCompressionPropertyKey_RealTime = true` と `AllowFrameReordering = false` を設定していると見られる**（＝ B フレームは既に無効）。したがって「B フレーム無効化」のために独自実装を書く前に、**まず実測する**。必要になった場合のみ `RTCVideoEncoderFactory` を差し替える。

先に手を入れるべきは以下（libwebrtc の外側で制御できる）:
- `RTCRtpEncodingParameters.maxBitrateBps` / `maxFramerate`（品質プリセット）
- `RTCRtpTransceiver` の `degradationPreference`
- ビデオトラックの `contentHint`

### 2.4 LocalServer

SwiftNIO の HTTP サーバに WebSocket アップグレードハンドラを載せる（NIO 標準の構成）。1 ポートで両方を捌ける。

- HTTP リスナ（:8422）と HTTPS リスナ（:8423）を同じハンドラで 2 本立てる。
- TLS は `NIOTSListenerBootstrap` + `NWProtocolTLS`。`SecIdentity` を渡す。
- 返すのは `Bundle.main` に入っている単一 HTML 1 つと、`/signal` の WebSocket のみ。ルーティングは実質 2 分岐。

証明書:

```
起動時:
  Keychain に既存の SecIdentity があるか（ラベル "net.sharkpp.doppelscreen.tls"）
    ある & SAN が現在の IP を含む → それを使う
    ない or IP が変わった        → swift-certificates で生成 → Keychain へ保存
```

- 秘密鍵は Keychain、証明書も Keychain（`SecIdentity` として取り出せる形）に置く。Application Support に平文で置かない。
- **SAN に全ての LAN IP を入れる。** `getifaddrs` で列挙する。
- **HSTS ヘッダを送らない**（SPEC.md §5.3）。

### 2.5 権限とネットワーク

- 画面収録: `CGPreflightScreenCaptureAccess()` で状態確認、`CGRequestScreenCaptureAccess()` で要求。拒否されている場合は `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture` でシステム設定へ誘導する。
- ローカルネットワーク: macOS 15+ ではローカルネットワークアクセスの許諾プロンプトが出る。オンボーディングに含める。
- LAN IP の列挙は `getifaddrs`、変化の監視は `NWPathMonitor`。

### 2.6 M0 の実装順

層を積み上げる。各ステップで動作を確認してから次へ進む。

1. **Xcode プロジェクト作成**（macOS App / SwiftUI / macOS 14+）、SPM 依存を追加
2. **画面収録権限のオンボーディング** — 権限がない状態で黙って動かない UI を先に作る
3. **SCStream で自己プレビュー** — キャプチャしたフレームをアプリ内の SwiftUI ビューに描画。**ネットワークを触る前にキャプチャを確定させる**
4. **libwebrtc をループバックで検証** — 同一プロセス内に 2 つの `RTCPeerConnection` を作って offer/answer を直結し、キャプチャ → エンコード → デコードが通ることを確認。シグナリングもブラウザも介さないので、問題の切り分けが容易
5. **HTTP サーバ**（:8422）で単一 HTML を返す。ブラウザで開けることを確認
6. **WebSocket シグナリング**（`/signal`）で SDP / ICE を交換し、ブラウザに映像を出す ← **ここで初めて end-to-end が通る**
7. **HTTPS リスナと証明書生成**を追加（:8423）
8. **遅延計測オーバーレイ** — ここまでを M0 とする

---

## 3. Windows ホスト（`apps/windows`）

| 用途 | 選定 |
| --- | --- |
| 言語 / ビルド | C++/WinRT + CMake + vcpkg |
| WebRTC | [shiguredo/webrtc-build](https://github.com/shiguredo/webrtc-build) の Windows x64 ビルド済みバイナリ |
| HTTP + WebSocket + TLS | Boost.Beast（Boost.Asio 上に HTTP / WS / TLS が揃う） |
| 証明書生成 | OpenSSL（Beast の TLS 依存として既に入る） |
| UI | WinUI 3（非パッケージ構成 + Windows App SDK ブートストラッパ） |

- **C# は選ばない。** WinRT 射影で `Windows.Graphics.Capture` は扱えるが、libwebrtc をネイティブに使えない。純 C# の WebRTC 実装（SIPSorcery 等）は帯域推定が未成熟で、SPEC.md §2.4 で webrtc-rs を却下したのと同じ理由で不適。
- エンコードは Media Foundation の H.264 ハードウェアエンコーダを `webrtc::VideoEncoderFactory` として登録する。libwebrtc の Windows ビルドは標準ではソフトウェアエンコーダしか持たないため、**ここは自前実装が必要**。macOS / Android と違って手間がかかる箇所。
- Boost.Beast が重いと判断した場合の代替は uWebSockets。ただし TLS の取り回しは Beast の方が素直。

---

## 4. Android ホスト（`apps/android`）

| 用途 | 選定 |
| --- | --- |
| 言語 / ビルド | Kotlin + Gradle |
| UI | Jetpack Compose |
| WebRTC | `io.github.webrtc-sdk:android`（Google が公開を止めた後の維持ビルド） |
| HTTP + WebSocket + TLS | Ktor Server（CIO エンジン） |
| 証明書生成 | `ktor-network-tls-certificates` の `buildKeyStore`（SAN 指定可） |

- キャプチャは libwebrtc 同梱の `ScreenCapturerAndroid` に `MediaProjection` を渡すだけで済む。**4 プラットフォーム中もっとも実装量が少ない。**
- `mediaProjection` タイプのフォアグラウンドサービス + 常時通知が必須。`MediaProjection` の同意は毎回必要で、これは無人アクセス不可の方針と整合する。
- Ktor は証明書生成から HTTPS 待受、WebSocket まで一式そろうため、ホスト 4 実装の中で LocalServer 周りがもっとも素直になる。

---

## 5. iOS ホスト（`apps/ios`）

| 用途 | 選定 |
| --- | --- |
| 言語 | Swift |
| キャプチャ | ReplayKit Broadcast Upload Extension |
| WebRTC / HTTP | macOS と同じ（`stasel/WebRTC` + SwiftNIO） |

**最大の制約はメモリ約 50MB。** PeerConnection と LocalServer を Broadcast Upload Extension の中で動かす必要がある（コンテナアプリはバックグラウンドで suspend されるため、接続を持てない）。これは Twilio / LiveKit などの iOS 画面共有実装が取っている構成でもある。

したがって実装方針:

- **macOS と同じコードを共有するが、メモリ計測を最優先で行う。** 最初にやるのは機能実装ではなく、「libwebrtc + NIO + H.264 エンコードが 50MB に収まるか」の確認。
- 収まらない場合の削減案（この順で検討）:
  1. NIO をやめ、`NWListener` + 手書きの最小 HTTP / WebSocket に置き換える
  2. キャプチャ解像度の上限を下げる
  3. コンテナアプリ側に LocalServer を置き、Extension とは App Group + Unix ドメインソケットで繋ぐ（アプリの suspend 問題が再燃するため最後の手段）
- **M5 の最初のタスクは「メモリに収まるかの検証」であり、収まらなければ設計を見直す。** 機能から作り始めない。

---

## 6. 共通事項

### 6.1 ビューアのバンドル

各ホストのビルドに、ビューアのビルドを組み込む。

```
apps/web/dist/index.html  →  ホストアプリのリソースへコピー
```

- macOS / iOS: Xcode の Run Script フェーズで `npm run build` を叩き、成果物を Copy Bundle Resources へ。
- Windows: CMake の `add_custom_command` で同様。
- Android: `assets/` へコピーする Gradle タスク。

ビューアのソースはホスト実装から独立させ、**ホスト側はビルド済みの 1 ファイルしか知らない**状態を保つ。

### 6.2 バージョン固定

- libwebrtc の版はプラットフォーム間でできる限り揃える。片方だけ更新して相互運用が壊れる事故を避ける。実際の版番号は `docs/adr/` に記録し、更新は明示的な判断として扱う。
- ビューアの `package-lock.json`、SPM の `Package.resolved`、vcpkg の baseline、Gradle の lockfile をすべてコミットする。

### 6.3 テスト

| 層 | 手段 |
| --- | --- |
| プロトコル（SPEC.md §7）のエンコード／デコード | 各言語の単体テスト（swift-testing / Vitest / GoogleTest / kotlin.test）。純粋関数として切り出す |
| 解像度追従・デバウンスのロジック | Vitest（ビューア側）、swift-testing（ホスト側） |
| 証明書生成（SAN・永続化・再生成条件） | 単体テスト。実機不要 |
| end-to-end | Playwright（ヘッドless Chromium）でビューアを開き、映像トラックが `getStats()` 上でフレームを受信していることを確認。macOS ランナーで実ホストを起動する |
| glass-to-glass 遅延 | 手動。カメラ同時撮影（SPEC.md §3.3）。リリースごとに記録 |

キャプチャ層は実機依存で CI に載せづらいため、**その周辺（プロトコル・証明書・追従ロジック）を実機なしでテストできる形に切り出しておく**ことが設計上の要件になる。

---

## 7. 要確認事項

実装着手時に最新の状況を確認する。本ドキュメントの記述は前提が変わりうる。

1. `stasel/WebRTC` の最新版が対応する macOS / iOS の最低バージョンと、同梱 libwebrtc の版
2. shiguredo/webrtc-build の Windows ビルドの提供状況と版
3. `io.github.webrtc-sdk:android` の維持状況（供給が止まった場合の代替）
4. libwebrtc の VideoToolbox エンコーダが実際に B フレームを無効化しているか（§2.3）
5. `RTCRtpReceiver.jitterBufferTarget` の Safari 対応状況（未対応なら iPad ビューアの遅延がどこまで下がるか）
6. macOS 15+ のローカルネットワークアクセス許諾がバックグラウンドの待受にどう影響するか
