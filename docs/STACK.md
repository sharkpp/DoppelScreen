# 技術スタックと実装方法

[SPEC.md](../SPEC.md) が「何を作るか」、本ドキュメントが「何で、どう作るか」を扱う。

ホストは 4 プラットフォームすべてネイティブ実装する。Dart/Flutter による共通化は検討のうえ却下した（[ADR 0001](adr/0001-host-implementation-stack.md)）。

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
- **`latency/` はビューアではない。** glass-to-glass 実測用のカウンタと解析（§2.11）。ビューアと同居させているのは、Node / Vite のツールチェーンがここにしかないためで、ビルドは別（`vite.latency.config.ts`）。依存も計測専用に増えている（`qrcode` で QR を作り、`zxing-wasm` で録画から読む）。

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

- 自己診断（SPEC.md §5.3）は `typeof RTCPeerConnection === "undefined"` の判定と、5 秒の
  タイムアウトの 2 段構え。**測るのは「シグナリングがホストへ届いたか」だけ** — 届いた後は
  ホストの承認待ちで何分でも止まりうるので（SPEC.md §5.2）、映像の到着で測ると
  承認を待っている人に「接続できません」と出してしまう。
  **HTTPS のポートはホストの `/config` に尋ねる。** 待受を始めるまで決まらず、HTML へ埋め込ませると
  ホストが成果物を書き換えることになって「ビルド済みの 1 ファイルしか知らない」前提が崩れる（§6.1）。
- 遅延オーバーレイは `pc.getStats()` の `jitterBufferDelay` / `totalDecodeTime` / `framesDropped` / RTT から作る
  （`src/latency.ts`）。**`getStats()` が返すのはほぼすべて接続してからの累積値で、そのまま
  `jitterBufferEmittedCount` や `framesDecoded` で割ると一生ぶんの平均になる。**
  一度跳ねた値が下がってこなくなり、いま何が起きているかを読めない
  （画面を大きく書き換えるとジッタが跳ね、その後ずっと高いまま — で気づいた）。
  **分子も分母も前回の観測との差分を取り、その 1 秒だけの平均にする。**
  静止していてフレームが来ない区間（SPEC.md §4.3）は割る相手がいないので直前の読みを持ち越す。
  0 を出すと「とても良い」に見えてしまう
  fps とビットレートは前回の観測との差分。読み出しは純粋関数に切り出して Vitest で確認する。
  RTT は `nominated` / `succeeded` の候補ペアだけを見る（落選した候補の値は意味がない）。
- ズームは CSS `transform` を使うが、**ズーム倍率 1.0 のときは `transform` を DOM から完全に外す**。合成レイヤが増えると表示遅延が乗る。
- 操作 UI は状態表示と 1 つの入れ物（`#overlay`）に縦へ積む。左右に離して置くと、
  幅が狭い端末で重なる。**入れ物は `pointer-events: none`** で、ボタンだけが押される —
  そうしないと映像のタップ（全画面切替）が操作 UI の見えない矩形に吸われる。
- **全画面と遅延オーバーレイはボタンで切り替える。** キーボードのない端末（ビューアの主用途は
  iPad）では `s` キーも映像のタップも届かない場所がある。iOS / iPadOS の Safari は要素の
  フルスクリーンを持たないため、`video.webkitEnterFullscreen()` へ落とす。
- 遅延オーバーレイの既定は非表示。モニタとして使っている間は映像だけを残す（SPEC.md §8.2）。

### 1.3 開発ループ

ホストアプリを毎回ビルドし直さずにビューアを触れるようにする。

- 開発時: `vite dev`（:5173）で開き、ホストの WS URL をクエリパラメータで渡す（`?host=192.168.1.10:8422`）。
- 本番: `vite build` → 単一 HTML をホストアプリのバンドルへコピー。macOS では XcodeGen の
  `postBuildScripts`（`apps/macos/scripts/build-viewer.sh`）が `npm run build` を叩き、
  `viewer.html` としてバンドルへ入れる。**コード署名より前に置く必要があるため、全ビルドフェーズの後に走らせる。**

### 1.4 E2E（`make e2e`）

Playwright でホストアプリを起動し、実ブラウザから繋いで映像が出るところまでを通しで確認する
（`apps/web/e2e/`）。ホストは検証モード（§2.10）で立ち上げるので、UI 操作はいらない。

- **`channel: "chrome"` を使う。Playwright 同梱の Chromium ではだめ。** 同梱ビルドはプロプライエタリ
  コーデックを含まず **H.264 をデコードできない**。接続はできるのに映像だけ出ない、という分かりにくい
  失敗になる（本製品は H.264 固定 — SPEC.md §2.5）。
- ビューア側は `videoWidth` と再生位置で、ホスト側は `report.json` の `framesSent` で判定する。
  **両側から見て突き合わせる**ことで、「送ったつもり」「映ったつもり」を潰す。
- 接続先は `127.0.0.1` を使う。LAN アドレスでも通るが、macOS 15 のローカルネットワーク許諾を
  巻き込まない分こちらが安定する。

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

### 2.3 エンコーダ設定（M1 で確定）

#### libwebrtc 既定のエンコーダファクトリは使えない

> **`RTCDefaultVideoEncoderFactory` は H.264 を level 3.1（`640c1f` / `42e01f`）として広告する。
> VideoToolbox は level の制限（最大フレームサイズ・最大ビットレート）を実際に強制するため、
> 1080p 以上や 40Mbps 上限では圧縮セッションが 1 枚も出力しない。**

実測（macOS 15.5 / Apple Silicon、`RTCVideoEncoderH264` を直接叩いて確認。上限 40Mbps）:

| 解像度 | level 3.0–3.2 | 4.0–4.2 | 5.0 以上 |
| --- | --- | --- | --- |
| 1920×1080（8160MB） | ✗ | ✓ | ✓ |
| 2880×1800（20340MB） | ✗ | ✗ | ✓ |

**症状が非常に分かりにくい。** libwebrtc は encode 失敗をコーデックの切り替えで隠すため、
`framesEncoded` は伸び続け、映像も出る。実際に流れているのは **VP8 のソフトウェア符号化**で、
ビューア側もハードウェアデコードできない。M0 の「コーデックは H.264」という実測は誤りだった
（下記の統計の読み違いも重なっていた）。

対処は `H264EncoderFactory`（`Sources/Video/VideoEncoderFactory.swift`）:

- **level 5.2 を広告する**（4K60 と 240Mbps を覆う）
- **ネゴシエートされた level を無視して符号化する。** level は answer で下げられる
  （Chrome も libwebrtc も 3.1 を返す）。`level-asymmetry-allowed=1` により送出側は自分の
  level を使ってよく、復号側が見るのは SDP ではなくビットストリーム中の SPS
- **H.264 以外を広告しない。** 失敗が静かなコーデック切り替えに化けず、そのまま表面化する
- level 5.2 を超える解像度（5K 以上のディスプレイ）は `VideoEncoding.encodableSize` で
  縮小してから渡す。縮小は `SCStream` 側で行われ、CPU 側のコピーは増えない

**`encoderImplementation` の統計を必ず見ること。** `VideoToolbox` 以外ならソフトウェアに落ちている。

#### 統計から「実際に使っているコーデック」を読む

`codec` の統計は**ネゴシエートされた全コーデックぶん**現れる。種別だけで拾うと使っていない
ものを掴む（実際に H.264 で流れているのに VP8 と報告された）。`inbound-rtp` / `outbound-rtp` の
`codecId` から引く（`RTCStatisticsReport.mimeType(of:)`）。

#### B フレームと GOP は既定で正しい

`WebRTC.framework` の未定義シンボルを見ると、`kVTCompressionPropertyKey_AllowFrameReordering`
`_RealTime` `_MaxKeyFrameInterval` をいずれも参照している（`nm -u`）。実測でも 15 秒で
`keyFramesEncoded` は 1–2 に留まり、**長 GOP + PLI が既定で効いている**。ここは触らない
（SPEC.md §3.2 のレバー 2 と 4 は追加実装不要）。

#### libwebrtc の外側で当てる設定（`VideoEncoding`）

- `RTCPeerConnection.setBweMinBitrateBps(min:current:max:)` — **これが解像度低下の本命**。
  `current` は帯域推定を**その場で強制する**ため、立ち上がりのランプアップ（300kbps 級）と
  それに伴うダウンスケールが消える
- `RTCRtpEncodingParameters` の `maxBitrateBps` / `minBitrateBps` / `maxFramerate` /
  `scaleResolutionDownBy = 1`
- `degradationPreference = maintainResolution` — 足りなくなったら解像度ではなく fps を落とす。
  ぼけた 60fps より鮮明な 30fps の方が役に立つ（SPEC.md §7.2）
- **適用はローカル記述を入れた後。** それより前は送出側のパラメータが確定していない
- ビデオトラックの `contentHint` は **obj-c API に無い**（`RTCVideoTrack` は
  `addRenderer` / `removeRenderer` しか持たない）。品質プリセット（M2）は上記の値で表現する

映像は `addTransceiver(direction: .sendOnly)` で張る。転送専用であることを SDP に明記し
（SPEC.md §1.2）、送出できないコーデックがネゴシエートされる余地も消える。

### 2.4 LocalServer

SwiftNIO の HTTP サーバに WebSocket アップグレードハンドラを載せる（NIO 標準の構成）。1 ポートで両方を捌ける。

- HTTP リスナ（:8422）と HTTPS リスナ（:8423）を同じハンドラで 2 本立てる。
- TLS は `NIOTSListenerBootstrap` + `NWProtocolTLS`。`SecIdentity` を渡す。
- 返すのは `Bundle.main` に入っている単一 HTML 1 つと、`/signal` の WebSocket のみ。ルーティングは実質 2 分岐。
- 希望のポートが埋まっていたら空きポートへずらし、**実際に確保できたポートを URL / QR に反映する**（SPEC.md §5.3）。

**トークンは WebSocket の最初の 1 通（`hello`）で運ぶ。** SPEC.md §5.1 の図は `Authorization` ヘッダだが、
ブラウザの `WebSocket` はヘッダを付けられない。クエリパラメータに置くとアクセスログや履歴に残り、
トークンを URL fragment に置いた意味が消える。認証は `LocalServer` が済ませ、`SessionController` には
**通ったものだけを渡す**。

実装上の落とし穴（すべて対処済み）:

- **WebSocket へ昇格したときに外れるのは、NIO が入れた HTTP のハンドラだけ。** 自前のページ配信ハンドラは
  パイプラインに残り、`WebSocketFrame` を `HTTPServerRequestPart` として取り出そうとして**プロセスごと落ちる**。
  症状は「アップグレードは成功するのに直後に 1006 で切れる」。昇格時の `completionHandler` で自分で外す。
- **ハンドラの参照は `@Sendable` なクロージャへ持ち込めない**（`ChannelHandler` は `Sendable` でない）。
  名前を付けて登録し、`removeHandler(name:)` で外す。
- **切断の理由を送ってから閉じるときは、必ず `ChannelHandlerContext` 経由で書く。** `Channel.writeAndFlush` は
  パイプラインの末尾から入るため `close` が先着し、**理由が届かないまま切れる**。
- **`ChannelHandlerContext` はイベントループに閉じており、クロージャへ持ち出せない。** 後で閉じたい場合は
  `Sendable` な `Channel` を捕まえておく。

証明書（`TLSIdentity`）:

```
待受の開始時:
  Keychain の証明書を全件読み、OU が "net.sharkpp.doppelscreen.tls" のものを探す
    ある & SAN が現在の IP を覆う → SecIdentityCreateWithCertificate で識別情報にする
    ない or IP が増えている       → swift-certificates で生成 → Keychain へ保存
```

- 秘密鍵は Keychain、証明書も Keychain（`SecIdentity` として取り出せる形）に置く。Application Support に平文で置かない。
- **SAN に全ての LAN IP と `127.0.0.1` を入れる。** `getifaddrs` で列挙する。ループバックは E2E と手元確認に要る。
- 古い IP が余分に残っているだけなら作り直さない。**ビューア端末が受け入れた証明書例外を無駄に無効化しない**ため。
- **HSTS ヘッダを送らない**（SPEC.md §5.3）。
- 証明書が用意できなくても HTTP だけで待ち受けを続ける。**HTTPS が立たないことを配信不能にしない。**

#### キーチェーンの落とし穴（実害が出た）

> **`SecItemCopyMatching` / `SecItemDelete` に `kSecClassIdentity` + `kSecAttrLabel` を渡してはいけない。**
> macOS の（レガシー）キーチェーンではこの絞り込みが効かず、**ラベルが一致しない他の識別情報を掴む**。
> 実装当初これをやった結果、`SecItemCopyMatching` が開発用の署名証明書「DoppelScreen Development」を
> 返し、SAN が合わないので作り直すべきと判断して `SecItemDelete` で**消してしまった**。
> 署名 ID が消えるとビルドが通らなくなり、作り直すと TCC から別アプリになって画面収録の許可もやり直しになる。

対処（実装済み）:

- **探すときは属性に頼らない。** 証明書を全件読み（`kSecMatchLimitAll`）、DER をパースして
  **中身**（OU = `net.sharkpp.doppelscreen.tls`）で自分のものだと判定する。
- **消すときは参照そのものを指す。** `kSecMatchItemList` に `SecCertificate` / `SecKey` の参照を渡す。
  属性で消すと、キーチェーンが属性を無視した場合に無関係な項目まで巻き込む。
- `SecIdentity` は `SecIdentityCreateWithCertificate` で証明書から作る。identity クラスへの問い合わせを避けられる。
- PKCS#12 は組み立てない。**秘密鍵と証明書をそれぞれ入れれば、キーチェーンが公開鍵ハッシュで結び付けてくれる。**
  `security import` 系で踏む「空パスワード不可」「OpenSSL 3 既定の暗号化を受け付けない」（§2.5）を回避できる。
- **`kSecUseDataProtectionKeychain: false` を明示する。** 付けないとデータ保護キーチェーンへ回され、
  `keychain-access-groups` エンタイトルメントを要求されて `errSecMissingEntitlement` で弾かれる。
  このエンタイトルメントには実 Team ID とプロビジョニングプロファイルが要り、自己署名の開発ビルドでは付けられない。
- **鍵に「どのプロセスからも確認なしで使える」利用許可を付ける**（`SecAccessCreate` +
  `SecACLSetContents(acl, nil, ...)`）。既定のまま（＝作成したアプリだけ）にすると、
  **アプリを更新した瞬間に HTTPS が黙って死ぬ。** 署名の変わった実行ファイルから鍵を使おうとすると
  キーチェーンが確認ダイアログを出そうとし、検証モード（§2.7）のように UI を持たないプロセスでは
  **そのまま返ってこない**。TCP は繋がるのに TLS ハンドシェイクが完了しない、という一番分かりにくい
  壊れ方をする（実際に踏み、`make e2e` の HTTPS 経路だけが落ち続けた）。
  `SecACLSetContents` の `applicationList` は **`nil` が「どのアプリでも可」**で、
  空配列は「どのアプリも不可」。意味が正反対なので注意する。
  この鍵が守るのは LAN 内の中間者だけで、同じ Mac 上のプロセスに対しては何も守っていない
  （画面を撮れる立場のプロセスは配信内容そのものを直接読める）。秘密は接続トークンと
  ホスト承認の側にある（SPEC.md §5.2）。
  なお `SecAccessCreate` 系は macOS 10.10 で deprecated だが、**ファイルベースのキーチェーンには
  代替がない**。上の `kSecUseDataProtectionKeychain: false` と同じ理由で、ここは警告を承知で使う。
- **鍵はキーチェーンの中で作る**（`SecKeyCreateRandomKey` + `kSecAttrIsPermanent`）。
  `SecKeyCreateWithData` で作った「浮いた」鍵を `kSecValueRef` で `SecItemAdd` に渡すと、
  ファイルベースのキーチェーンは項目参照として受け付けず `errSecInvalidItemRef` を返す。
  作ってから `SecKeyCopyExternalRepresentation` で取り出し、swift-certificates に署名させる
  （EC の秘密鍵は **ANSI X9.63 形式** = `04 || X || Y || K` で出入りする）。
  証明書のほうは `SecCertificateCreateWithData` で作った参照をそのまま `SecItemAdd` に渡してよい。

### 2.5 権限とネットワーク

- 画面収録: `CGPreflightScreenCaptureAccess()` で状態確認、`CGRequestScreenCaptureAccess()` で要求。拒否されている場合は `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture` でシステム設定へ誘導する。

#### 画面収録権限の落とし穴（3 つとも実装で対処済み）

1. **`CGRequestScreenCaptureAccess()` がプロンプトを出せるのはアプリごとに一度きり。** 以降は何も起きず false を返すだけで、ボタンが無反応に見える。「一度尋ねたか」を `UserDefaults` に記録し、二度目以降はシステム設定へ直接誘導する。
2. **システム設定で許可しても実行中のプロセスには反映されない。再起動が要る。** UI に再起動ボタンを置く（`NSWorkspace.openApplication` + `createsNewApplicationInstance` → 完了後に `NSApp.terminate`）。
3. **TCC は署名でアプリの同一性を判定する。** ad-hoc 署名（`CODE_SIGN_IDENTITY: "-"`）では cdhash がビルドごとに変わり、**リビルドすると別アプリ扱いになって許可が失われる。** システム設定のリストには残ったまま実際には拒否されるため、原因が分かりにくい。
   - **対処済み: 開発用の自己署名証明書で署名する。** `make macos-dev-certificate` でログインキーチェーンに作り、`project.yml` の `CODE_SIGN_IDENTITY` に指定している。Designated Requirement が `identifier "net.sharkpp.doppelscreen" and certificate leaf = H"…"` になり、cdhash に依存しなくなるため**リビルドしても許可が維持される**。検証モード（§2.7）を手動許可なしで回すための前提でもある。
   - Apple Development 証明書を用意したら `CODE_SIGN_IDENTITY` を差し替えるだけで移行できる。
   - 署名 ID を切り替えた直後は同一性が変わるため、一度だけ `make macos-reset-permission` してから許可し直す。

   証明書作成時の落とし穴（`scripts/create-dev-certificate.sh` で対処済み）:
   - Security.framework は**空パスワードの PKCS#12 を読めない**。使い捨てのパスワードを付ける
   - OpenSSL 3 既定の AES-256-CBC + PBKDF2 も受け付けない。`openssl pkcs12 -export -legacy` で書き出す
   - `extendedKeyUsage=codeSigning` と `security add-trusted-cert -p codeSign` の両方が要る。どちらかが欠けると `find-identity -v -p codesigning` が有効な ID として扱わない
   - `security import -T /usr/bin/codesign` を付けても、**初回ビルドでキーチェーンの確認ダイアログが 1 回だけ出る**。「常に許可」を押す。非対話で抑えるには `security set-key-partition-list` が必要だが、ログインキーチェーンのパスワード入力を伴うため行わない
   - **`ENABLE_DEBUG_DYLIB` を `NO` にする。** Xcode 16 は既定で SwiftUI プレビュー用の `*.debug.dylib` を分離して出力する。Team ID を持たない自己署名では本体と Team ID が食い違い、`dyld` が読み込みを拒否して**起動即クラッシュ**する（`Library not loaded: @rpath/DoppelScreen.debug.dylib`）
- ローカルネットワーク: macOS 15+ ではローカルネットワークアクセスの許諾プロンプトが出る。オンボーディングに含める。
- LAN IP の列挙は `getifaddrs`、変化の監視は `NWPathMonitor`。

### 2.6 ディスプレイ構成の変更に追従する

ディスプレイは実行中に増減し、解像度も変わる。追従しないと **UI の一覧・選択と、実際に動いているストリームが食い違う**。3 経路すべてを塞ぐ。

| 経路 | 対処 |
| --- | --- |
| 接続・切断・解像度変更・配置変更 | `NSApplication.didChangeScreenParametersNotification` を `SessionController` が購読して一覧を取り直す。**UI ではなくコントローラで購読する**（ウィンドウを閉じてメニューバーだけになっても追従させるため） |
| キャプチャ中のディスプレイの解像度変更 | ディスプレイ ID が変わらないので一覧の変化としては見えない。`DisplayStream.update(display:)` が `DisplayInfo` の差を見て、制御チャネルへ `display` を流し、解像度追従をやり直す |
| ストリームの自発的な停止 | `SCStreamDelegate.stream(_:didStopWithError:)`。`delegate: nil` で作ると握り潰され、止まっているのに UI が「実行中」のまま残る |

- 一覧から**消えた**ディスプレイの `DisplayStream` は停止して破棄する。生き残った画面のストリームは作り直さない（作り直すと配信中の接続が切れる）。
- 待受の開始・停止とディスプレイ一覧の更新は UI 操作とシステム通知の両方から届く。順序が入れ替わると競合するため、**すべて単一の直列キューに通す**（`SessionController.enqueue`）。画面ごとのキャプチャ開始・停止・再構成も同様に `DisplayStream` 側で直列化する。

### 2.7 検証モード（`--selftest`）

人がプレビューを目視しなくてもキャプチャの健全性を確認できるようにする。

```
make macos-selftest
make macos-selftest SELFTEST_ARGS="--display 1 --duration 5"
make macos-selftest SELFTEST_ARGS="--loopback"        # WebRTC まで通す（§2.9）
```

UI を出さずに、権限判定 → ディスプレイ列挙 → 指定秒キャプチャ → **最終フレームを PNG 保存** → レポート JSON を書き出して終了する。出力は `apps/macos/build/selftest/`（`report.json` と `frame.png`）。

- `deliveredFrames` が伸びていればキャプチャが届いている。`idleFrames` が伸びていれば静止時の抑制（SPEC.md §4.3）が効いている。実測では、操作中のメインディスプレイが 3 秒で 154 配信 / 13 idle、静止した仮想ディスプレイが 2 秒で **1 配信 / 77 idle** と、はっきり差が出る。
- `displays` にディスプレイ一覧が入るため、抜き差しの前後で実行すれば**列挙が実態と合っているか**を確認できる。
- `frame.png` を開けば実際に何が映っていたかが分かる。

実装上の注意:

- **`open` で起動する。実行ファイルを直接叩かない。** TCC は「責任プロセス」で許諾を判定するため、ターミナルから直接起動するとターミナルの許諾が参照され、結果が実態と食い違う。
- **`open -W` は使えない。** 検証モードは `NSApplication` を起動しないので LaunchServices が追跡できず、`kevent() failed: No such process` になる。レポートの出現をポーリングして待つ。
- **PNG の書き出しはストリームを止める前に行う。** 停止後はピクセルバッファが回収されうる。
- `LocalServer` の `/debug` には載せない。LAN に開くサーバへデバッグ経路を常駐させたくないのと、起動〜キャプチャ〜終了を通しで見るほうが回帰検出に向くため。

### 2.8 M0 の実装順

層を積み上げる。各ステップで動作を確認してから次へ進む。

1. **Xcode プロジェクト作成**（macOS App / SwiftUI / macOS 14+）、SPM 依存を追加
2. **画面収録権限のオンボーディング** — 権限がない状態で黙って動かない UI を先に作る
3. **SCStream で自己プレビュー** — キャプチャしたフレームをアプリ内の SwiftUI ビューに描画。**ネットワークを触る前にキャプチャを確定させる**
4. **libwebrtc をループバックで検証** — 同一プロセス内に 2 つの `RTCPeerConnection` を作って offer/answer を直結し、キャプチャ → エンコード → デコードが通ることを確認。シグナリングもブラウザも介さないので、問題の切り分けが容易
5. **HTTP サーバ**（:8422）で単一 HTML を返す。ブラウザで開けることを確認
6. **WebSocket シグナリング**（`/signal`）で SDP / ICE を交換し、ブラウザに映像を出す ← **ここで初めて end-to-end が通る**
7. **HTTPS リスナと証明書生成**を追加（:8423）
8. **遅延計測オーバーレイ** — ここまでを M0 とする

### 2.9 WebRTC ループバック検証（`--loopback`）

同一プロセス内に `RTCPeerConnection` を 2 つ作り、offer / answer を直結する。シグナリングもブラウザも介さないため、**libwebrtc 自体の問題とその外側の問題を切り分けられる**。

`make macos-selftest SELFTEST_ARGS="--loopback"` で、キャプチャ → H.264 エンコード → 転送 → デコード → 描画までを 1 回で確認し、**デコード後のフレームを `decoded.png` に書き出す**。`frame.png`（キャプチャ直後）と見比べればピクセル経路の正しさが分かる。

実装上の落とし穴（すべて対処済み）:

- **`rtpReceiver.track` は呼ぶたびに新しいラッパーを返す。保持しないと解放時にレンダラごと外れる。** デコードは進むのにフレームが 1 枚も届かない、という分かりにくい症状になる。
- **受信トラックへのレンダラ接続を `didAdd rtpReceiver:` に頼らない。** 任意実装のデリゲートで、呼ばれるかどうかが libwebrtc の版に依存する。`setRemoteDescription` 後に `receiver.receivers` から明示的に取る。
- **リモート記述が入る前に届いた ICE candidate は捨てられる。** 宛先が決まるまで溜めて、決まった時点で流す。
- **`withCheckedContinuation` はキャンセルできない。** `withTaskGroup` でタイムアウトと競争させても、グループは全ての子タスクの完了を待つため、解放されない継続を抱えたまま永久に止まる。タイムアウトも「同じ継続を一度だけ解放する」形で表現する。
- **hardened runtime のライブラリ検証は本体と同じ Team ID を要求する。** 自己署名では `WebRTC.framework` を読み込めず起動時にクラッシュするため、Debug では無効にする（§2.5）。
- **macOS 15 のローカルネットワーク許可が下りるまで ICE は checking のまま進まない。** candidate の収集（インタフェース列挙）は成功するので、症状が「接続だけしない」となり原因が分かりにくい。`candidate-pair` の `requestsSent` / `responsesReceived` を見れば「送れていない」のか「返ってこない」のかを切り分けられる。

実測（メインディスプレイ 2880×1800、5 秒、M1 後）: エンコード 321 / デコード 319 / 描画 319、
`video/H264`、`encoderImplementation` は `VideoToolbox`、**デコード解像度 2880×1800**。

M0 時点では 960×600 に落ちており、かつ実際には VP8 のソフトウェア符号化だった（§2.3）。
`decoded.png` が `RTCI420Buffer` で書き出せない場合はソフトウェアデコード＝コーデックの
切り替えが起きているサイン。

### 2.10 配信の検証（`--serve`）

`--selftest --serve` で、UI を出さずに実際の配信経路（キャプチャ → `LocalServer` → `PeerTransport`）を
立ち上げ、ビューアの接続を待つ。

```
make macos-serve                                  # 接続先を表示して待つ
make macos-serve SELFTEST_ARGS="--duration 120"
make e2e                                          # Playwright から自動で繋ぐ（§1.4）
```

**`SessionController` をそのまま駆動するため、製品と同じ経路を検証する。** キャプチャ側の検証（§2.7）が
`ScreenCapturer` を直接叩くのと対照的で、こちらは配線ごと確認する。

- 待受を開始した時点で `serve.json`（ポート・トークン・URL）を書く。E2E 側はこれを合図にブラウザを開く。
  終了時の `report.json` には `framesSent` / `codec` / `encoderImplementation` / `encodeMs` /
  `keyFramesEncoded` / `qualityLimitationReason` / `candidatePairs` が入る。
- **`--duration` は「合計の実行時間」。** 繋がってから使い切るまで配信を続ける。
  接続の 3 秒後に切っていた頃は、手で繋ぐと画面が出た直後に切れていた。
- 実測（メインディスプレイ 2880×1800、Chrome へ 15 秒、M1 後）: **送出 442 フレーム、`video/H264`、
  `VideoToolbox`、解像度 2880×1800 のまま、`qualityLimitationReason` は `none`。**

**承認は迂回しない。** `--serve` は「承認待ちの `DisplayStream` を見つけたら `approve()` を押す」
ループを回すだけで、製品と同じ承認経路を通る（§2.12）。承認を素通りする裏口を作ると、
検証しているのが製品ではなくなる。

実装上の落とし穴（対処済み）:

- **`startServing()` は直列キューへ積むだけで、戻った時点ではまだ `.idle`。** 「`.starting` ではない」で
  待つと積む前の状態を拾って素通りする。`.running` / `.failed` で待つ。
- **HTTPS の待受が「繋がるのに応答しない」場合はキーチェーンの確認ダイアログを疑う。** 証明書の
  取得（`SecIdentity`）は通るが、TLS ハンドシェイクでの秘密鍵の使用は許可を要求する。
  ダイアログが未応答のまま残っていると `ERR_TIMED_OUT` / `ERR_CONNECTION_REFUSED` になる。
  「常に許可」を一度押す。`certificateError` は `nil` のままなので、ログからは分からない。

### 2.11 遅延の実測（M1）

「低遅延」は計測できなければ検証できない（SPEC.md §3.3）。2 段構えで測る。

#### 内訳の自動計測（`make e2e`）

E2E の「遅延の内訳を実測して記録する」が、**ビューア側とホスト側の両方**から統計を読み、
`apps/macos/build/selftest/latency.json` に残す。リグレッションはここで検出する。

- ビューア側は `getStats()`（`jitterBufferDelay` / `totalDecodeTime` / RTT）を `src/latency.ts` の
  純粋関数で読む。**`jitterBufferTarget` の実効値は統計に出ないため、`page.addInitScript` で
  `RTCPeerConnection` を捕まえてレシーバ本体から読む**（0 でなければジッタバッファを捨てられていない）
- ホスト側は `report.json` の `encodeMs` / `packetSendMs` / `keyFramesEncoded`

実測（2880×1800@60、有線ではなくローカルループバック、Chrome）:

| 区間 | 実測 | バジェット（SPEC.md §3.1） |
| --- | --- | --- |
| エンコード | **17.4ms** | 3–8ms |
| パケット化・送信 | 2.0ms | ~1ms |
| ネットワーク（RTT） | 1.0ms | 1–5ms |
| ジッタバッファ | 8.3ms | 0–10ms |
| デコード | 7.2ms | 3–8ms |
| 合計（表示を除く） | **約 36ms** | 12–32ms |

**エンコードだけがバジェットを大きく超える。原因は解像度。** 同じ経路を 1824×1140 に落とすと
エンコードは **9.9ms**、ジッタバッファ 6.5ms、破棄フレームも 14 → 1 に減る。
2880×1800 は 1080p の 2.5 倍の画素数で、SPEC.md §3.1 のバジェットは 1080p60 前提である。

→ **解像度追従（SPEC.md §7.1、M2）がそのまま最大の遅延削減策になる。** ビューアの表示画素数に
合わせれば、多くの場合エンコードは 10ms 以下に収まる。M1 では上限（level 5.2）だけを見て、
既定はディスプレイの実解像度のままとした。

#### 解像度追従を入れた後（M2、同じ経路・同じマシン）

ビューアは Chrome の既定ビューポート 1280×720。追従の結果、送出は **1152×720** になった。

| 区間 | M1（2880×1800） | M2（1152×720） | バジェット |
| --- | --- | --- | --- |
| エンコード | 17.4ms | **7.8ms** | 3–8ms |
| パケット化・送信 | 2.0ms | 3.0ms | ~1ms |
| ネットワーク（RTT） | 1.0ms | 3.0ms | 1–5ms |
| ジッタバッファ | 8.3ms | 15.4ms | 0–10ms |
| デコード | 7.2ms | 3.5ms | 3–8ms |
| 合計（表示を除く） | 約 36ms | **約 33ms** | 12–32ms |

**予想どおりエンコードがバジェット内に入った**（画素数は 1/6.25）。デコードも半分以下になる。
一方で**ジッタバッファが 8.3 → 15.4ms に増えている**。`jitterBufferTarget = 0` は効いている
（E2E が実効値 0 を確認している）ので、これは「目標 0 でも実際には詰まる」側の値であり、
測定時のマシンの負荷にも揺れる。

#### ジッタバッファの値は立ち上がりを含んでいた（2026-08-13 に訂正）

**上の 2 つの表のジッタバッファとデコードは、接続してからの累積平均で読んでいた**（§1.2 のバグ）。
E2E は最初から 1 秒差で 2 回読んでいたのに、その差分を使っていたのは fps とビットレートだけで、
ジッタバッファと復号時間は「接続してからの全フレームの平均」のままだった。
**接続直後の立ち上がりが一生残る**ため、定常状態より高く出る。

区間平均に直して同じ経路で測り直すと（1152×720、ループバック、Chrome）:

| 区間 | 累積平均での記録 | 区間平均（2026-08-13） |
| --- | --- | --- |
| ジッタバッファ | 15.4ms | **0.2ms** |
| デコード | 3.5ms | **2.6ms** |

**「解像度追従を入れたらジッタバッファが 8.3 → 15.4ms に増えた」は測り方の側の話だった。**
`jitterBufferTarget = 0` はローカルループバックでは効き切っていて、実質ゼロで受けている。
ここはもう削る余地がない — **削るならエンコードと表示側**（SPEC.md §11-2）。

**またこの表は glass-to-glass の分解には使えない。** ループバック・Chrome・内蔵ディスプレイ・
1152×720 で測ったもので、実際に撮影した経路（外部ディスプレイ・iPad・Wi-Fi）とは条件が違う。
**67ms（下記）の内訳が欲しいなら `make macos-serve` で同じ経路を測る。**

#### glass-to-glass の実測 — 2026-08-11 時点で 67ms（目標 60ms に未達）

自動計測（9481 コマ）で**中央値 67ms、p10 50ms、p90 116ms**。Wi-Fi・iPad 10.2
（[docs/latency-measurements.md](latency-measurements.md)）。中央値は 60Hz のちょうど 4 フレームで、
p10 は 3 フレーム。**あと 1 フレーム削れば目標に入る**位置にいる。

**先に手読みで得ていた 50ms は取り下げた。** 標本が約 10 コマしかなく、しかも人は
「読みやすいコマ」を選ぶぶん短い側に偏る。**標本数が 3 桁違う自動計測を採る。**
これが計測を自動化した理由そのものでもある。

**解像度追従は実機で意図どおり動いていた。** 内蔵ディスプレイ 2880×1800 に iPad 10.2
（表示領域 2160×1620）を繋いだとき、送出は 2304×1440 — `VideoEncoding.followingSize` の
計算と一致する。ただし 3.32 Mpx はバジェットが前提にする 1080p の 1.6 倍で、
**エンコードが重い側に効いている疑いがある**（外挿で 13ms 前後。同条件の内訳を取るまで未確認）。

**人の手が要るのは撮影だけ。読み取りは自動化してある。手順と記録は
[docs/latency-measurements.md](latency-measurements.md) に集約する**
（SPEC.md §3.3 の「リリースごとに同条件で記録し、リグレッションを検出する」の実体）。

```
make latency-clock                              # カウンタを全画面表示（apps/web/latency/）
make latency-analyze VIDEO=~/Desktop/IMG_0001.MOV   # 録画から遅延を出す
```

ホストとビューアを 1 台のカメラで同時に高速度撮影し、同じフレームに写った 2 つのカウンタの
差を読む。**カウンタは毎フレーム全体が描き替わるので、変化駆動のキャプチャも同時に働く**
（静止画を映すと静止時の送出停止が効いて、遅延ではなく「止まっていること」を測ってしまう）。

カウンタは読み取り手段を 3 つ重ねてある。**上から順に自動化に向く。**

- **QR（主）**: 経過ミリ秒（1000 秒周期）。`latency/analyze.mjs` が録画から読む。
  **位置も取れるので、どちらの画面かを人が指定する必要がない** — 時刻が新しい方が必ずホスト。
  6 桁に収めて version 1（21×21 モジュール）で固定する。桁を増やして版が上がると、
  ビューア側で縮小されたときに読めなくなる
- **数字**: QR と同じ時刻の下 4 桁。QR が読めなかったときに人が読む
- **ブロック**: 1 個 = 表示 1 フレーム。**桁がブレて読めないコマでも位置の差は残る**
- **リフレッシュレートは決め打ちせず実測して表示する。** 60Hz 前提で「1 ブロック 16.7ms」と
  固定すると、120Hz の画面や省電力で落ちている状態で黙って倍ずれる

解析（`latency/analyze.mjs`）は ffmpeg から**生の RGBA を流し込んで** `zxing-wasm` で
1 コマから QR を**すべて**読み、時刻差の中央値を採る。人が 10 コマ読んでいたものが
数百コマになる。中間ファイルは作らない — 1080p の PNG を全コマ書き出すと、10 秒の
240fps 動画で数 GB になる（QR は非可逆圧縮で読めなくなりうるので JPEG で軽くもできない）。

**撮影レートはコンテナの申告を信じず、QR に載ったホストの時刻から算出する。** iPhone の
スローモーションは 240fps のコマを 30fps 再生の尺で書き出すため `avg_frame_rate` は 30 に
なる（コマは間引かれないので遅延の測定には影響しない）。ホストの時刻を基準時計として
「コマがどれだけ実時間を刻んでいるか」を測れば、どちらの書き出し方でも実レートが出る。

- **値が変わったコマ（表示フレームの境目）だけを使う。** 表示は 60Hz なので 240fps で撮ると
  4 コマ続けて同じ QR になり、1 コマごとの差は 0 が並ぶだけ。単純に全体の両端を使うと
  端点に「まだ値が変わっていない待ち時間」が最大 1 表示フレームぶん乗り、**短い録画で
  240fps が 276fps に化ける**
- 隣り合う境目どうしの差の中央値は採らない。QR の時刻は 1ms に丸めてあるので 16ms と 17ms が
  交互に出て数 % 偏る。**最初と最後の境目だけを使えば丸めが打ち消える**
- 間引きは `--every N`（コマ番号）で行う。`fps=` フィルタは**コンテナの時刻**で動くので、
  スローモーションではコマが複製されたり落ちたりする

**解析そのものは自動で検証している。** `e2e/latency-tool.spec.ts` が、カウンタの静止モード
（`?t=<ミリ秒>`）で**既知の遅延を埋め込んだ動画を合成**し、解析がその値を言い当てるかを見る。
確かめられないのはカメラ由来のもの（ブレ・ローリングシャッター・ピント・反射）だけで、
QR の生成・H.264 を経た劣化・複数 QR の検出・ホストの判定・周期のまたぎ・統計は全部通る。

計測ページは Vite の別ビルド（`vite.latency.config.ts`）で単一 HTML に落とす。
ビューア本体と同じビルドに混ぜると出力先を食い合い、ホストのバンドルへ入れるファイルが
どちらか分からなくなる。単一 HTML なので `file://` でそのまま開ける — 撮影する端末に
サーバを立てさせない。

### 2.12 画面ごとの配信と承認（M2）

**URL を画面ごとに分ける**（SPEC.md §5.2）。`?d=<displayID>` を付けた URL を別々の端末で開けば、
複数の画面を同時にミラーリングできる。

```
http://192.168.1.10:8422/?d=1#<token>     ← 内蔵ディスプレイ
http://192.168.1.10:8422/?d=7#<token>     ← 外部ディスプレイ
```

- `DisplayStream` が画面 1 枚ぶんの `ScreenCapturer` + `VideoPipeline` + `PeerTransport` を持つ。
  `SessionController` は権限・一覧・待受・振り分けだけを見る。
- **`RTCPeerConnectionFactory` は 1 つを共有する。** 画面ごとに作ると VideoToolbox のセッションも
  人数分増える。トラック ID だけ `screen-<displayID>` で分ける。
- ビューアは `hello` に画面を載せる。**指定された画面が見つからないときは、黙って別の画面へ
  フォールバックしない。** 意図しない画面を配信するほうが有害なので、理由を返して切る。
- プレビュー（`PreviewRenderer`）は複数のストリームから同時にフレームを受けるので、
  `source` で映す画面を選び、他は捨てる。

**キャプチャはホストが承認して初めて開始する**（SPEC.md §5.2）。

- 待受を始めた時点では**何も撮っていない**。ビューアが来ると `.awaitingApproval` になり、
  ホストが「承認」を押して初めて `SCStream` が動く。**承認前に画面の内容が符号化されることがない**、
  という形で無人アクセス不可を保証する。
- ビューアが去ったらキャプチャも止める。静止時の送出停止（SPEC.md §4.3）と同じ理屈で、
  CPU・電力・発熱に効く。

### 2.13 制御チャネルと解像度追従（M2）

DataChannel `control` を 1 本だけ持つ（SPEC.md §7）。**offer を作る前に張る** — 後から足すと
再ネゴシエートが要る。

| 向き | メッセージ |
| --- | --- |
| ホスト → ビューア | `hello` / `display` / `stats`（1 秒ごと）/ `error` |
| ビューア → ホスト | `viewport` |

コーデックは両側とも純粋関数に切り出す（`ControlMessage.swift` / `control.ts`）。

**解像度追従**（SPEC.md §7.1）が M2 最大の遅延削減策（§2.11）。

- ビューアは表示できる領域を**物理ピクセル**で申告する（`innerWidth × devicePixelRatio`）。
  CSS ピクセルで送ると高 DPI 端末が実解像度の半分しか受け取れない。
- ホストは `VideoEncoding.followingSize` で 720p / 1080p / 1440p / 2160p の**直近上位**へ丸める。
  実解像度にぴったり合わせるとリサイズのたびにエンコーダの再構成とキーフレームが走る。
  ビューアはレターボックス表示するので、使われる画素数は「はみ出さない側」で決まる。
- 500ms のデバウンスをかけてから当てる。リサイズ中は `viewport` が連続で届く。
- 当て方は **`SCStream.updateConfiguration`**。ストリームを張り直すと切り替えのたびに
  数フレーム落ちてキーフレームからやり直しになる。

### 2.14 ペアリングと QR（M2）

`PairingService` がトークンの発行・期限・検証をまとめて持つ（SPEC.md §5.2）。
`LocalServer` はこれを渡されるだけで、照合の中身を知らない。

| 決めごと | 値 | 理由 |
| --- | --- | --- |
| 期限 | 5 分 | 古い QR の写真では繋がらないようにする |
| 期限切れの扱い | 次に読まれたときに作り直す | 画面に出ている QR は常に生きている |
| 接続確立時 | **失効させない** | 失効させると 2 画面目を繋げない（SPEC.md §5.2） |
| 失敗 5 回 | トークンを作り直す | 1 つのトークンに対する試行を 5 回で打ち切る |
| 同じ相手からの失敗 | 30 秒の窓で 5 回まで | 作り直しても試行され続けるので、頻度そのものを抑える |

- **成功はレート制限の枠を使わない。** ビューアは自動で繋ぎ直す（§2.15）ため、
  正しい端末が自分で枠を食い潰す形にしてはいけない。
- トークンの照合は定数時間で行う。LAN 内とはいえ、比較時間で当てられる余地を残さない。
- **QR は `CIQRCodeGenerator`（CoreImage）で作る。** 外部ライブラリを足す理由がない。
  補間して拡大するとモジュールの境界がぼけて読み取り率が落ちるので、整数倍に拡大してから
  ラスタライズし、`Image.interpolation(.none)` で描く。
- QR には**トークンと画面を含む完全な URL** が入る。既定は HTTP で、HTTPS も併記する
  （SPEC.md §5.3）。URL 文字列は QR が読めない環境の代替として残す。

### 2.15 再接続と承認の関係（M2）

ビューアは切れたら自動で繋ぎ直す（SPEC.md §11-4）。素直に作ると**繋ぎ直すたびにホストで
「承認」を押すことになり**、ネットワークが一瞬切れただけでモニタとして使えなくなる。

そこで**再接続チケット**を持つ。承認して配信が始まった直後に、ホストが制御チャネルで
使い切りのチケットを渡す（`{"t":"resume","ticket":"…","ttlMs":600000}`）。ビューアはこれを
`sessionStorage` に置き、次の `hello` に載せる。通ればホストは接続トークンの照合も承認も省く。

- **接続トークンの期限（5 分）とは独立させる。** 長く映しているうちにトークンが回っても、
  繋ぎっぱなしのビューアが切れてはいけない。
- **チケットは画面に紐づける。** 画面 A の承認で画面 B が映せてはいけない。
- **寿命は 10 分。** ネットワーク断・スリープ復帰・ディスプレイ構成変更を跨ぐには足りて、
  「席を外している間に勝手に繋がれる」には足りない長さにする。長く取ると無人アクセスを
  禁じた前提（SPEC.md §1.2）が崩れる。
- **人が「切断」を押したらその画面のチケットを無効にする。** 切ったつもりのビューアが
  黙って戻ってきてはいけない。
- ビューアは繋ぎ直しても直らない理由（トークン不正・期限切れ・試行過多・承認拒否・画面なし）
  では**繰り返さない**。繰り返すとホストのレート制限に自分で引っかかる。

### 2.16 品質プリセット（M2）

ビューアが選び、ホストが当てる（SPEC.md §7.2）。実際に動くのは 3 つだけ。

| プリセット | 上限 fps | 上限ビットレート | `degradationPreference` |
| --- | --- | --- | --- |
| `sharp`（既定） | 30 | 20 Mbps | `maintain-resolution` |
| `balanced` | 60 | 30 Mbps | `maintain-resolution` |
| `smooth` | 60 | 40 Mbps | `maintain-framerate` |

- **上限 fps はキャプチャ側にも当てる**（`SCStreamConfiguration.minimumFrameInterval`）。
  エンコーダだけで絞ると、撮ってから捨てるぶんの CPU と電力が無駄になる。
- **`contentHint` は当てない。** W3C の送出側 API で、libwebrtc の Objective-C SDK には
  対応するプロパティがない（`RTCVideoTrack` に無い）。ホストがネイティブである以上
  ブラウザ側からも触れないため、`contentHint` が意図していた挙動を
  `degradationPreference` と上限 fps で表す。
- プリセットは接続ごとに既定へ戻す。次に繋いでくるのは別のビューアかもしれない。
  ビューア側は繋ぎ直したときに自分の選択を送り直す。

### 2.17 配布（署名・notarization）

`apps/macos/scripts/release.sh`（`make macos-release`）。Developer ID 証明書と
notarytool の資格情報は開発者ごとに用意し、リポジトリには入れない。手順はスクリプト冒頭。

- **`codesign --deep` を使わない。** 入れ子の署名要件を潰してしまい、Apple も非推奨にしている。
  `Contents/Frameworks` を先に署名してから本体を署名する。
- notarization には **hardened runtime（`--options runtime`）と secure timestamp が必須**。
  Release 構成では `ENABLE_HARDENED_RUNTIME: YES`。
  開発ビルドで NO にしているのは、自己署名証明書が Team ID を持たず、ライブラリ検証が
  `WebRTC.framework` の読み込みを拒否するため（§2.1）。
- 圧縮は **`ditto -c -k --keepParent`**。`zip` コマンドは拡張属性を落として署名を壊す。
- 依存のライセンス表示は `scripts/bundle-licenses.sh` が `Contents/Resources/Licenses/` へ入れる。
  libwebrtc（BSD 3-Clause）も swift-*（Apache-2.0）もバイナリ配布の条件にしている
  （[THIRD-PARTY-NOTICES.md](../THIRD-PARTY-NOTICES.md)）。**リリースのときだけ入れると忘れるので、
  開発ビルドから同じ形で入れる。**

### 2.18 ホスト UI の構え

**このアプリはメニューバーに常駐し、Dock アイコンを持たない**（`LSUIElement`）。配信している間に
ユーザが見ているのは配信中の画面そのもので、ホストの UI はそこに居座るべきものではない。

- **自分の画面のプレビューを持たない。** 目の前にある画面をもう一度小さく映す意味がない。
  ウィンドウが受け持つのはペアリング（QR / URL）と承認、そして「いま何が誰へ流れているか」だけ。
  プレビューを外したぶん、フレームを複製する経路（`AVSampleBufferVideoRenderer`）ごと消えている。
- **どの画面を映すかを選ぶ UI も持たない。** 画面ごとに URL が分かれる（SPEC.md §5.2）以上、
  選ぶのはビューア側で URL を開く行為そのものであり、ホストで選ばせると二重になる。
- 待受の開始・停止はウィンドウのツールバー（主操作）とメニューの両方に置く。
  **承認だけはウィンドウに限る**（§2.15）— 相手のアドレスと対象の画面が並んで見える場所でだけ押せるようにする。
- **Dock アイコンを持たないと、SwiftUI は起動時にウィンドウを前に出さない。**
  何も出ないと初回の権限オンボーディングに辿り着けないため、`applicationDidFinishLaunching` で
  `identifier == "main"` のウィンドウを明示的に前へ出す。ウィンドウ自体は SwiftUI が作っているので、
  ここでやるのは並べ替えだけでよい。
- 「DoppelScreen について」も OS が用意しない（アプリメニューが無い）。`AboutView` を
  メニューバーから開くウィンドウとして自前で持つ。

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

### 6.2 文言（`i18n/`）

**文言の出どころは `i18n/<言語>.yaml` の 1 か所**（SPEC.md §11-7）。ここを直して `make i18n` を
実行すると、各プラットフォームの形式へ変換される。生成物はコミットする — そうしないと
macOS のビルドに Node が要るようになる。

| 出力先 | 形式 | 受け持つ範囲 |
| --- | --- | --- |
| `apps/macos/Sources/Resources/<言語>.lproj/Localizable.strings` | Apple 標準の `.strings` | `host.*` |
| `apps/macos/Sources/Generated/L10n.swift` | キーと引数の型だけを持つ入り口 | `host.*` |
| `apps/web/src/generated/strings.ts` | 全言語を埋め込んだモジュール | `viewer.*` |

- **macOS は `.strings` をそのまま吐き、言語の選択は OS に任せる。** 自前の言語選択を持つと、
  システム設定の「アプリごとの言語」が効かなくなる。`L10n` が持つのはキーの綴りと引数の型だけ。
- **ビューアは全言語をコードに埋め込む。** 単一 HTML で配信する（§6.1）以上、言語ファイルを
  実行時に取りに行く経路を持てない。選択は読み込み時に 1 回だけ（`navigator.languages`）。
- 置き換えは `{name}`。訳文で語順が変わってよいように、`.strings` へは番号付きの
  書式指定子（`%1$@`）で書き出す。訳が欠けていたり置き換えの名前が食い違うと `make i18n` が落ちる。

**ホストがビューアへ送るエラーは、文言ではなくコードで送る。**
ホストの表示言語とビューアの表示言語は一致しない（Mac は日本語、手元の iPad は英語、という
組み合わせが普通にある）。`{"t":"error","code":"token_expired"}` を受けて、ビューアが
`viewer.error.*` から自分の言語で出す（`apps/web/src/errors.ts`）。`detail` は OS 由来の説明など、
コードにできない補足だけに使う。

Windows / Android / iOS のホストを足すときは、`tools/i18n/` に出力先を 1 つ追加する
（`swift.mjs` と同じ形の render 関数を書き、`generate.mjs` の `targets` に並べる）。

### 6.3 アイコン（`assets/icon/`）

**原本は `assets/icon/doppelscreen.svg` の 1 枚だけ**で、各 OS のサイズは `make icon` が書き出す。
ビットマップを直接編集しない。生成物（`apps/macos/Sources/Resources/AppIcon.icns`）はコミットする。

- 変換は `tools/icon/generate.swift`。**SVG の解釈を AppKit（`NSImage`）に任せている**ため、
  外部の変換ツール（rsvg / Inkscape / ImageMagick）を要求しない。
- **各サイズは原本から直接ラスタライズする。** 1024 の PNG を作って縮小して回すと、
  16px 側で輪郭が濁る。ベクタのまま各サイズへ描くほうが小さい側が保つ。
- 絵は「画面が二重像になる」— 奥に半透明の分身、手前に実体。**16px まで縮めても崩れないよう、
  要素は 2 枚の画面と台座だけに絞っている。**
- Windows / Android / iOS を足すときは、`generate.swift` に出力先を 1 つ追加する
  （`.ico` / mipmap / `AppIcon.appiconset`）。原本は増やさない。

`AboutView` はこの `.icns` を `NSImage(named: "AppIcon")` で読む。`NSApp.applicationIconImage` は
Dock タイルを持たないアプリ（§2.18）では差し替え前の仮画像を返すことがある。

### 6.4 バージョン固定

- libwebrtc の版はプラットフォーム間でできる限り揃える。片方だけ更新して相互運用が壊れる事故を避ける。実際の版番号は `docs/adr/` に記録し、更新は明示的な判断として扱う。
- ビューアの `package-lock.json`、SPM の `Package.resolved`、vcpkg の baseline、Gradle の lockfile をすべてコミットする。

### 6.5 テスト

| 層 | 手段 | コマンド |
| --- | --- | --- |
| プロトコル（SPEC.md §7）のエンコード／デコード | swift-testing / Vitest。純粋関数として切り出す | `make macos-test` / `make web-test` |
| ペアリング（期限・失敗回数・レート制限・再接続チケット） | swift-testing | `make macos-test` |
| 解像度追従・デバウンスのロジック | Vitest（ビューア側）、swift-testing（ホスト側） | 同上 |
| 言語定義と生成物の整合 | 生成しなおして差分を見る | `make i18n-check` |
| end-to-end | Playwright + 実 Chrome。macOS ランナーで実ホストを起動する | `make e2e` |
| glass-to-glass 遅延 | 手動。カメラ同時撮影（SPEC.md §3.3）。リリースごとに記録 | `make latency-clock` |

キャプチャ層は実機依存で CI に載せづらいため、**その周辺（プロトコル・ペアリング・追従ロジック）を実機なしでテストできる形に切り出しておく**ことが設計上の要件になる。

**Swift のテストバンドルはアプリをテストホストにしない。** ホストにすると実行のたびに
アプリが起動して UI と TCC が絡み、CI に載らなくなる。代わりに `Sources`（`App/` を除く）を
テストバンドルへ直接取り込む。同一モジュールになるので `@testable import` も要らない。

期限まわり（トークンの TTL、レート制限の窓、再接続チケットの寿命）は `PairingService` の
イニシャライザで注入できるようにしてある。**5 分待たないと確かめられない作りにしない。**

証明書生成（`TLSIdentity`）はキーチェーンに触るため、この単体テストには含めていない。
確認は `make macos-serve` と E2E の HTTPS 経路で行う。

---

## 7. 要確認事項

実装着手時に最新の状況を確認する。本ドキュメントの記述は前提が変わりうる。

1. `stasel/WebRTC` の最新版が対応する macOS / iOS の最低バージョンと、同梱 libwebrtc の版
2. shiguredo/webrtc-build の Windows ビルドの提供状況と版
3. `io.github.webrtc-sdk:android` の維持状況（供給が止まった場合の代替）
4. ~~libwebrtc の VideoToolbox エンコーダが実際に B フレームを無効化しているか~~ → **確認済み。無効。
   長 GOP も既定で効いている**（§2.3）。代わりに level の広告が壊れていることが分かった
5. `RTCRtpReceiver.jitterBufferTarget` の Safari 対応状況（未対応なら iPad ビューアの遅延がどこまで下がるか）。
   Chrome では 0 を設定でき、ジッタバッファは 8.3ms まで下がることを実測（§2.11）
6. macOS 15+ のローカルネットワークアクセス許諾がバックグラウンドの待受にどう影響するか
7. `SecAccessCreate` 系（deprecated）の代替。ファイルベースのキーチェーンには現状 代替がなく、
   データ保護キーチェーンへ移すには実 Team ID とプロビジョニングプロファイルが要る（§2.4）。
   Developer ID での配布に移った時点で、`kSecUseDataProtectionKeychain: true` に寄せられるか確認する
