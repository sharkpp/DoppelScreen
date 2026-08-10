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
  **HTTPS のポートはホストの `/config` に尋ねる。** 待受を始めるまで決まらず、HTML へ埋め込ませると
  ホストが成果物を書き換えることになって「ビルド済みの 1 ファイルしか知らない」前提が崩れる（§6.1）。
- 遅延オーバーレイは `pc.getStats()` の `jitterBufferDelay` / `totalDecodeTime` / `framesDropped` / RTT から作る
  （`src/latency.ts`）。**累積値なので、`jitterBufferEmittedCount` や `framesDecoded` で割って 1 フレームあたりに直す。**
  fps とビットレートは前回の観測との差分。読み出しは純粋関数に切り出して Vitest で確認する。
  RTT は `nominated` / `succeeded` の候補ペアだけを見る（落選した候補の値は意味がない）。
- ズームは CSS `transform` を使うが、**ズーム倍率 1.0 のときは `transform` を DOM から完全に外す**。合成レイヤが増えると表示遅延が乗る。

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
| キャプチャ中のディスプレイの解像度変更 | ディスプレイ ID が変わらないので選択の変化として検知できない。**`ScreenCapturer.Configuration` そのものを比較**して、違えば貼り直す |
| ストリームの自発的な停止 | `SCStreamDelegate.stream(_:didStopWithError:)`。`delegate: nil` で作ると握り潰され、止まっているのに UI が「実行中」のまま残る |

- キャプチャ中のディスプレイが**消えた**場合は、黙って別の画面へ切り替えない。停止して理由を表示する（意図しない画面を映し続けるほうが有害）。
- 開始・停止・再構成は UI 操作とディスプレイ構成変更の両方から届く。順序が入れ替わると再起動が競合するため、**すべて単一の直列キューに通す**（`SessionController.enqueue`）。

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

実測（メインディスプレイ 2880×1800、3 秒）: エンコード 185 / デコード 184 / 描画 184、コーデックは `video/H264`。**ただしデコード解像度は 960×600 に落ちる。** 立ち上がり時の帯域推定によるダウンスケールで、解像度追従（SPEC.md §7.1）とビットレート設定は M1 / M2 で扱う。

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
  終了時の `report.json` には `framesSent` / `codec` / `candidatePairs` が入る。
- 実測（メインディスプレイ 2880×1800、Chrome へ 8 秒）: **送出 180 フレーム / 受信 181 フレーム、`video/H264`、
  ICE は `succeeded sent=5 received=5`。** ただし解像度は 960×600 に落ちる（§2.9 のループバックと同じく
  立ち上がりの帯域推定によるもの。解像度追従は M1 / M2）。

実装上の落とし穴（対処済み）:

- **`startCapture()` は直列キューへ積むだけで、戻った時点ではまだ `.idle`。** 「`.starting` ではない」で
  待つと積む前の状態を拾って素通りする。`.running` / `.failed` で待つ。

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
