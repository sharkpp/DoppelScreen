# DoppelScreen 設計仕様

PC / モバイル端末の画面をリアルタイムに配信し、ブラウザ上で表示・遠隔操作するためのソフトウェア。

- **ホスト (Host)**: 画面を提供する側。macOS / Windows / Android / iOS で動作するネイティブアプリ。本リポジトリの主対象。
- **ビューア (Viewer)**: 画面を表示・操作する側。ブラウザで動く HTML アプリ。専用アプリは作らない。
- **ランデブー (Rendezvous)**: ホストとビューアを引き合わせるだけのシグナリングサービス。映像・入力は一切通さない。

---

## 1. 前提と非目標

### 1.1 前提

| 項目 | 内容 |
| --- | --- |
| 実装優先度 | macOS → Windows → Android → iOS |
| 伝送方式 | WebRTC（映像 = SRTP、入力 = DataChannel） |
| ビューア | ブラウザのみ（Chrome / Edge / Safari / Firefox の現行版） |
| 接続形態 | 1 ホスト : 1 ビューア（v1） |
| 想定遅延 | 同一 LAN で glass-to-glass 100ms 以下 |
| ドメイン | `sharkpp.net` |

### 1.2 非目標（v1 で作らない）

- ビューア側ネイティブアプリ
- ホスト同士の相互接続、多対多会議
- 無人常時稼働サーバ（無人アクセスは将来検討、v1 は同意ベース）
- ファイル転送、リモート印刷、セッション録画

---

## 2. アーキテクチャ

### 2.1 全体像

```
┌─────────────────────────┐                    ┌────────────────────────┐
│  Host (native app)      │                    │  Viewer (browser)      │
│                         │                    │                        │
│  ScreenCapturer  ──┐    │                    │   <video>              │
│   (platform API)   │    │                    │      ▲                 │
│                    ▼    │   SRTP (H.264)     │      │                 │
│  VideoTrack ───────────────────────────────────────>│                 │
│                         │                    │                        │
│  InputInjector <───┐    │   SCTP DataChannel │   PointerEvent /       │
│   (platform API)   └<───────────────────────────── KeyboardEvent      │
│                         │                    │                        │
│  SessionController      │                    │   SessionClient        │
└──────────┬──────────────┘                    └───────────┬────────────┘
           │                                               │
           │            WSS (SDP / ICE, E2E 暗号化)         │
           └──────────────► Rendezvous (sharkpp.net) ◄──────┘
                                    │
                              STUN / TURN
```

**シグナリングだけがクラウドを経由し、映像と入力はホスト⇔ビューアの直接経路（P2P）を通る。** 同一 LAN の場合 ICE は LAN 内候補を選ぶため、実際のトラフィックは外に出ない。

### 2.2 実装方針: プラットフォームごとにネイティブ実装、共有するのは「プロトコル」と「ビューア」

画面キャプチャと入力注入は 4 プラットフォームで API が完全に別物であり、共通化できる余地がほとんどない。共有コアを FFI で持ち込むより、**ワイヤプロトコルを厳密に定義し、各プラットフォームは自言語の慣用に従って実装する**方が総複雑度が低い。

| 層 | 共有 | 実体 |
| --- | --- | --- |
| プロトコル（§5, §6） | ✅ 全プラットフォーム共通 | 本ドキュメント + JSON Schema |
| ビューア | ✅ 1 実装 | TypeScript / Vite |
| ランデブー | ✅ 1 実装 | Cloudflare Workers + Durable Objects |
| WebRTC スタック | ⚠️ 同一ライブラリ（libwebrtc）、バインディングは各言語 | ObjC / Java / C++ |
| キャプチャ・入力注入・UI | ❌ 各プラットフォーム固有 | Swift / C++ / Kotlin |

### 2.3 ホスト側の内部モジュール（全プラットフォーム共通の構造）

各プラットフォームで同じ責務分割を守る。名前も揃える。

| モジュール | 責務 | 依存 |
| --- | --- | --- |
| `ScreenCapturer` | 画面フレームの取得。ディスプレイ／ウィンドウ選択、カーソル合成、更新検知 | OS API |
| `VideoPipeline` | フレーム → WebRTC VideoTrack への投入、解像度・fps 制御 | libwebrtc |
| `PeerTransport` | PeerConnection、DataChannel、ICE、統計 | libwebrtc |
| `SignalingClient` | ランデブーとの WSS 通信、SDP/ICE の E2E 暗号化 | — |
| `PairingService` | ペアリングコード生成、鍵導出、有効期限管理 | — |
| `InputInjector` | 入力イベント → OS への注入。座標変換、キーマップ | OS API |
| `SessionController` | 状態機械、権限（閲覧のみ／操作可）、切断処理 | 上記すべて |
| `HostUI` | 権限オンボーディング、コード表示、接続状況、キルスイッチ | — |

`SessionController` 以外は互いを直接参照しない。特に `InputInjector` は `PeerTransport` を知らない（プロトコル型のみ受け取る）。

### 2.4 WebRTC ライブラリ

**Google libwebrtc を全プラットフォームで採用する。** ビルド済みバイナリ（[shiguredo/webrtc-build](https://github.com/shiguredo/webrtc-build) 等）を使い、自前ビルドは行わない。

理由:
- 輻輳制御（GCC / TWCC ベースの帯域推定）が実用水準にある唯一の選択肢。画面配信の品質はこれで決まる。
- macOS/iOS の VideoToolbox、Android の MediaCodec によるハードウェアエンコードが標準で統合済み。
- ブラウザ実装と同じ系譜のため相互運用の事故が少ない。

**採用しなかった案**: `webrtc-rs` による Rust 共有コア。トランスポートは書けるが帯域推定が未成熟で、画質・遅延の要である輻輳制御を自作することになる。また iOS の Broadcast Extension・Android の MediaProjection は結局ネイティブ実装が必要で、共有できる範囲が想定より狭い。

### 2.5 コーデック

- **v1: H.264（High Profile, CABAC）**。全プラットフォームでハードウェアエンコード可能かつ Safari を含む全ブラウザがデコード可能。
- 画面向けの符号化効率では AV1 / VP9 が優位（スクリーンコンテンツ符号化ツール）だが、ハードウェアエンコード対応が限定的。**AV1 は将来、両端が対応している場合のみネゴシエーションで選択**する（SDP の優先順位で自然に扱えるため、追加設計は不要）。

---

## 3. プラットフォーム別実装

### 3.1 macOS（第一優先）

| 項目 | 採用技術 |
| --- | --- |
| 言語 / UI | Swift / SwiftUI（`MenuBarExtra` によるメニューバー常駐） |
| キャプチャ | ScreenCaptureKit (`SCStream`) — macOS 12.3+ |
| エンコード | VideoToolbox（libwebrtc 内蔵の Apple エンコーダファクトリ） |
| 入力注入 | Quartz Event Services (`CGEvent`) |
| Bundle ID | `net.sharkpp.doppelscreen` |
| 配布 | Developer ID 署名 + notarization（**Mac App Store 非対応**） |
| 更新 | Sparkle |

**キャプチャ詳細**
- `SCContentFilter` でディスプレイ / ウィンドウ / アプリ単位を選択。`SCStreamConfiguration` で `width`/`height`/`minimumFrameInterval`/`showsCursor`/`queueDepth` を制御。
- ピクセルフォーマットは `kCVPixelFormatType_420YpCbCr8BiPlanarFullRange`。`CVPixelBuffer` を `RTCCVPixelBuffer` でラップして `RTCVideoSource` に渡す。CPU 側でのコピーは行わない。
- フレーム添付の `SCStreamFrameInfo.status` が `.idle` のフレームは破棄し、静止時の送出を抑える。`.dirtyRects` は将来の部分更新最適化の材料として保持のみ。
- カーソルは v1 では `showsCursor = true` で映像に焼き込む。将来、遅延低減のためカーソル位置を DataChannel で別送しクライアント側描画に切り替える余地を残す（プロトコル §6 に `cursor` メッセージを予約済み）。

**入力注入詳細**
- `CGEventCreateMouseEvent` / `CGEventCreateScrollWheelEvent` / `CGEventCreateKeyboardEvent` を `CGEventPost(.cghidEventTap, _)` で送出。
- ドラッグ中は `.leftMouseDragged` を使う。連続クリックは `.mouseEventClickState` を設定してダブルクリックを成立させる。
- スクロールは `.pixel` 単位を優先（慣性スクロールとの親和性）。

**必要な権限（TCC）**
1. **画面収録** — キャプチャに必須。初回はシステム設定への誘導が必要。
2. **アクセシビリティ** — `CGEvent` 注入に必須。`AXIsProcessTrustedWithOptions` で状態確認と誘導。

権限オンボーディングは初回起動フローとして明示的に設計する（未許諾のまま黙って動かない状態を作らない）。

**既知の制約**
- ログインウィンドウ、FileVault 解除画面はユーザセッション外のためキャプチャできない。
- Secure Input（パスワード欄などで有効化）が有効な間はキーイベント注入が届かない可能性がある → **要検証（§9-A）**。
- `NSWindowSharingType.none` 指定のウィンドウ、および DRM 保護コンテンツは黒画像になる。仕様として許容する。

### 3.2 Windows（第二優先）

| 項目 | 採用技術 |
| --- | --- |
| 言語 | C++/WinRT（libwebrtc の C++ API を直接使うため） |
| キャプチャ | Windows.Graphics.Capture (`GraphicsCaptureItem` + `Direct3D11CaptureFramePool`) |
| エンコード | Media Foundation H.264 HW エンコーダを libwebrtc の `VideoEncoderFactory` として登録 |
| 入力注入 | `SendInput`（`MOUSEEVENTF_ABSOLUTE \| MOUSEEVENTF_VIRTUALDESK`、ホイールは `MOUSEEVENTF_WHEEL` / `HWHEEL`） |

**既知の制約**
- UIPI により、自プロセスより高い整合性レベルのウィンドウには入力を注入できない。UAC プロンプト・セキュアデスクトップ・ログオン画面も同様。
- 完全な操作には SYSTEM 権限のサービス + ユーザセッションのエージェントという二段構成が必要になる。**v1 ではユーザ権限のみ**とし、制限をビューアに明示する。サービス化は M4 以降の独立した課題として扱う。

### 3.3 Android（第三優先）

| 項目 | 採用技術 |
| --- | --- |
| 言語 | Kotlin |
| キャプチャ | `MediaProjection` + `VirtualDisplay` → libwebrtc の `ScreenCapturerAndroid` |
| 入力注入 | `AccessibilityService.dispatchGesture()`（既定） / Shizuku 経由の `input` 相当（任意） |

**制約と設計上の帰結**
- `MediaProjection` は毎回ユーザ同意が必要で、`mediaProjection` タイプのフォアグラウンドサービスと常時通知が必須（Android 14+ で厳格化）。
- Android は一般アプリによる任意の入力注入を許さない。`AccessibilityService` でできるのは**タップ・長押し・スワイプ・システムナビゲーション**まで。任意のキー入力は不可。
- したがって **Android ホストへの「右クリック」は存在しない**。プロトコルは意味論的イベント（§6.3）を持ち、ホスト側で最も近い操作にマップする（右クリック → 長押し）。
- Google Play のアクセシビリティ API ポリシーに抵触するリスクがある。**要判断（§9-D）**。

### 3.4 iOS（第四優先・**閲覧専用**）

| 項目 | 採用技術 |
| --- | --- |
| 言語 | Swift |
| キャプチャ | ReplayKit Broadcast Upload Extension (`RPBroadcastSampleHandler`) |
| 入力注入 | **不可能** |

**制約と設計上の帰結**
- 端末全体のキャプチャは Broadcast Upload Extension でしか行えない。Extension は独立プロセスかつ **メモリ上限が約 50MB** と厳しく、ここで PeerConnection を保持する必要がある（ホストアプリは suspend されうるため）。フレームのコピーを増やす実装は即クラッシュする。
- 脱獄していない iOS では入力注入手段が存在しない。**iOS ホストは閲覧専用**であり、ビューアには操作 UI を出さない（`capabilities` で通知、§6.1）。

---

## 4. 接続と信頼

### 4.1 接続シーケンス

```
Host                        Rendezvous                    Viewer (browser)
 │                              │                              │
 ├─ WSS connect ───────────────►│                              │
 ├─ create room ───────────────►│                              │
 │◄─ roomId ────────────────────┤                              │
 │                              │        https://screen.sharkpp.net を開く
 │  [ペアリングコード + QR を画面に表示]                          │
 │                              │◄─ join(roomId) ──────────────┤   ← QR / コード入力
 │◄─ peer joined ───────────────┤                              │
 │                              │                              │
 ├─ offer (E2E 暗号化) ─────────►├─ relay ─────────────────────►│
 │◄─ answer (E2E 暗号化) ───────┤◄─ relay ─────────────────────┤
 ├◄──── ICE candidates (E2E 暗号化、双方向リレー) ──────────────►│
 │                              │                              │
 │◄═══════ DTLS-SRTP / SCTP（直接またはTURN経由）═══════════════►│
 │                              │                              │
 │  [ホスト UI に「接続要求」を表示 → ユーザが承認]                 │
 ├─ hello(capabilities) ────────────────────────────────────────►│
 │◄─ 映像配信開始 ───────────────────────────────────────────────►│
```

### 4.2 ペアリングと E2E 認証

ランデブーサーバは信頼しない前提で設計する。画面の内容は極めて機微であり、サーバによる中間者攻撃を成立させてはならない。

1. ホストは 8 文字（32 文字アルファベット = 40bit）以上のワンタイムコードを生成し、画面に文字列と QR で表示する。QR には `https://screen.sharkpp.net/#<roomId>.<code>` を埋め込む。
2. 両者は `HKDF(code, salt=roomId)` からセッション鍵を導出する。
3. **SDP と ICE candidate は、この鍵による AEAD（AES-GCM）で暗号化してからランデブーに渡す。** サーバは中身を読めず、書き換えれば復号に失敗する。
4. SDP には DTLS フィンガープリントが含まれるため、これが保護されていれば以降のメディア経路の真正性が保証される。
5. コードの有効期限は 3 分。失敗試行はランデブー側でレート制限し、5 回で room を破棄する。

**採用しなかった案**: SPAKE2 等の PAKE。理論的には短いコードでも安全だが、40bit のワンタイムコード + 短い TTL + レート制限で必要な強度は満たせるため、実装・監査コストに見合わない。

### 4.3 操作権限

- ビューアは**必ず閲覧のみで接続を開始する**。
- ホストの UI で明示的に「操作を許可」をトグルしない限り、`InputInjector` はイベントを一切受け付けない（トランスポート層ではなく `SessionController` で落とす）。
- ホスト UI には常時、接続中インジケータと**即時切断ボタン**を置く。操作中は視覚的に判別できる表示を出す。
- 操作許可はセッション限りで、切断時に必ず失効する。

### 4.4 ランデブーサービス

- Cloudflare Workers + Durable Objects。room ごとに 1 つの Durable Object が WebSocket 2 本を保持し、暗号化済みメッセージを転送するだけ。状態は roomId・接続数・TTL のみ。
- STUN は Google の公開サーバ、TURN は必要になった時点で `turn.sharkpp.net`（coturn）を用意する。**TURN の運用コストは帯域従量であり、無条件に有効化しない**（§9-C）。

---

## 5. メディアパイプライン

### 5.1 品質制御

- `RTCRtpSender` の `degradationPreference = maintain-resolution` を設定する。画面共有では文字の可読性がフレームレートより重要。
- ビデオトラックの `contentHint = "text"`（テキスト主体）/ `"detail"`（図表・動画混在）をプリセットで切り替える。
- 品質プリセット（ホスト UI で選択）:

| プリセット | 解像度 | fps | ビットレート上限 |
| --- | --- | --- | --- |
| 文字重視 | 原寸（最大 4K） | 15 | 4 Mbps |
| 標準 | 最大 1920px 幅 | 30 | 8 Mbps |
| 動き重視 | 最大 1280px 幅 | 60 | 12 Mbps |

- 実効ビットレートは libwebrtc の帯域推定に従い、上限のみを与える。

### 5.2 静止時の抑制

`SCStreamFrameInfo.status == .idle` 相当（Windows: フレーム未着、Android: Surface 更新なし）の間はフレームを送出しない。ただしビューアの再接続・キーフレーム要求（PLI）には即応する。モバイルホストのバッテリと発熱に直結するため、v1 から実装する。

### 5.3 ビューア側の描画

- `<video autoplay playsinline muted>` に `MediaStream` を割り当てる。`muted` は自動再生要件のため必須。
- `requestVideoFrameCallback` で表示フレームのタイムスタンプを取得し、`RTCPeerConnection.getStats()` と合わせて遅延を実測・表示する。
- ピンチズーム・パンは CSS transform でクライアント側のみで行い、ホストには伝えない。

---

## 6. 制御プロトコル（DataChannel）

### 6.1 チャネル構成

| ラベル | 信頼性 | 順序 | 用途 |
| --- | --- | --- | --- |
| `control` | reliable | ordered | ハンドシェイク、クリック、キー、テキスト、意味論的操作、状態通知 |
| `pointer` | `maxRetransmits: 0` | unordered | ポインタ移動のみ（欠落・追い越し許容） |

ポインタ移動を分離するのは、高頻度イベントによる head-of-line blocking でクリック応答が遅れるのを防ぐため。**クリック・キーイベントは自身の絶対座標を持つ**ので、チャネル間の順序が保証されなくても操作は正しく成立する。ホストは `seq` が後退した移動イベントを破棄する。

### 6.2 メッセージ形式

JSON（v1）。1 メッセージ 1 イベント。フィールドは短縮名。

**ホスト → ビューア**

```jsonc
// 接続直後に 1 回。ビューアの UI 構成を決める
{ "t": "hello",
  "platform": "macos",            // macos | windows | android | ios
  "surface": { "w": 3456, "h": 2234, "scale": 2 },
  "capabilities": {
    "control": true,              // 操作を受け付けうるか（iOS は false）
    "buttons": ["left","right","middle"],
    "keyboard": true,
    "text": true,                 // IME 経由のテキスト入力
    "gestures": ["back","home","recents"],  // モバイルホストのみ
    "scrollUnits": ["px","line"]
  }
}

{ "t": "control", "granted": true }             // 操作許可の変化
{ "t": "surface", "w": 1920, "h": 1080, "scale": 1 }  // 解像度・ディスプレイ変更
{ "t": "cursor", "x": 0.51, "y": 0.32, "kind": "arrow" }  // 予約（v1 未使用）
{ "t": "error", "code": "control_denied", "message": "…" }
```

**ビューア → ホスト**

```jsonc
// pointer チャネル
{ "t": "pm", "x": 0.5123, "y": 0.3310, "seq": 10423 }

// control チャネル
{ "t": "pd", "x": 0.5123, "y": 0.3310, "b": 0, "mods": 4 }   // press
{ "t": "pu", "x": 0.5123, "y": 0.3310, "b": 0, "mods": 4 }   // release
{ "t": "scroll", "x": 0.5, "y": 0.5, "dx": 0, "dy": -120, "unit": "px", "mods": 0 }
{ "t": "key", "code": "KeyA", "down": true, "mods": 8 }
{ "t": "text", "s": "こんにちは" }
{ "t": "gesture", "g": "back" }
{ "t": "mode", "pointer": "absolute" }          // absolute | relative
```

- **座標は 0.0–1.0 の正規化値**。キャプチャ面のサイズ・スケール変更や、ビューア側のズーム・レターボックスから独立する。ホストは自身の座標系に変換する。
- `b`: 0=左, 1=中, 2=右。
- `mods`: ビットフラグ。1=Shift, 2=Control, 4=Alt/Option, 8=Meta(Cmd/Win)。
- `unit`: `px` は物理ピクセル相当、`line` は行単位。ブラウザの `WheelEvent.deltaMode` から変換する。

### 6.3 キーボードとテキスト

- `code` は DOM の `KeyboardEvent.code`（**物理キー位置**）を使う。ホスト側で macOS 仮想キーコード / Windows スキャンコード / Android キーコードへマップする。レイアウト差の吸収を各ホストの責務に閉じ込める。
- **日本語入力などの IME 変換結果はキーイベントから復元できない。** ビューアは非表示の入力要素で `compositionend` / `beforeinput` を捕捉し、確定文字列を `text` メッセージで送る。ホストは `CGEvent` の `keyboardSetUnicodeString`（macOS）、`KEYEVENTF_UNICODE`（Windows）で注入する。
- 修飾キーの意味論は変換しない。ビューアが Mac、ホストが Windows のような組み合わせでの Cmd/Ctrl 入れ替えは、ビューア側の設定として提供する（§9-F）。

### 6.4 ビューアの入力モードとタッチ操作

デスクトップ画面をタッチデバイスで操作する場合、絶対座標のタップだけでは精度が出ない。**2 つのモードを持つ。**

| モード | 用途 | 挙動 |
| --- | --- | --- |
| Absolute（既定） | マウス操作、モバイルホスト | タップした位置にそのままポインタを置く |
| Relative（トラックパッド） | 細かい操作、デスクトップホスト | 指の移動量でカーソルを相対移動。表示位置とカーソル位置が独立 |

タッチジェスチャのマッピング（Absolute モード）:

| ジェスチャ | 送信するイベント |
| --- | --- |
| タップ | `pd`/`pu` (b=0) |
| 長押し（500ms） | `pd`/`pu` (b=2) — 右クリック |
| 2 本指タップ | `pd`/`pu` (b=2) — 右クリック |
| 2 本指ドラッグ | `scroll` |
| ピンチ | クライアント側ズーム（ホストへ送らない） |
| ドラッグ（長押し後） | `pd` → `pm` … → `pu` |

マウス／キーボード利用時:
- Pointer Events API（`pointerdown`/`pointermove`/`pointerup`、可能なら `pointerrawupdate`）で統一的に扱う。
- Relative モードでは **Pointer Lock API** でマウスを捕捉する。
- **Keyboard Lock API**（`navigator.keyboard.lock()`、フルスクリーン時・Chromium のみ）で Cmd+Tab / Esc などを横取りする。非対応ブラウザでは該当キーが送れない旨を UI に出す。
- `pm` はブラウザ側で `requestAnimationFrame` に合わせて間引く（最大 60Hz）。

---

## 7. リポジトリ構成

```
/
├── SPEC.md                  ← 本ドキュメント
├── AGENTS.md
├── README.md
├── apps/
│   ├── macos/               Swift / SwiftUI（M0〜）
│   ├── web/                 TypeScript + Vite ビューア（M0〜）
│   ├── windows/             C++/WinRT（M4〜）
│   ├── android/             Kotlin（M5〜）
│   └── ios/                 Swift + Broadcast Extension（M6〜）
├── services/
│   └── rendezvous/          Cloudflare Workers + Durable Objects（M1〜）
└── docs/
    └── adr/                 アーキテクチャ決定記録
```

ビューアは v1 ではフレームワークを使わず TypeScript のみで実装する（映像面 + オーバーレイ + 設定シートに留まるため）。設定項目やセッション管理 UI が増え、状態管理が手書きで破綻し始めた時点で Svelte の導入を検討する — この判断は ADR に残す。

---

## 8. マイルストーン

各段階で「動く製品」を維持する。未完成の機能を抱えたまま次に進まない。

| # | 内容 | 完了条件 |
| --- | --- | --- |
| **M0** | 骨格 | macOS ホストがメインディスプレイをキャプチャし、同一 LAN のブラウザに映像が出る。room 固定、閲覧のみ |
| **M1** | 接続 | ランデブー + ペアリングコード + QR + STUN。異なるネットワーク間で接続できる |
| **M2** | 操作 | マウス・スクロール・キーボード・IME テキスト入力。操作許可トグル。Absolute/Relative モード |
| **M3** | 実用化 | 権限オンボーディング、再接続（ICE restart）、品質プリセット、ディスプレイ選択、署名・notarize 済みリリース |
| **M4** | Windows | ホスト実装（ユーザ権限の範囲） |
| **M5** | Android | ホスト実装（キャプチャ + AccessibilityService 操作） |
| **M6** | iOS | ホスト実装（閲覧専用） |
| **M7** | 拡張 | クリップボード同期、音声、複数ビューア |

---

## 9. 未決事項・設計の不足点

> 実装前に判断が必要な項目。優先度順。

### A. 要検証（技術的に確認しないと設計が確定しない）

1. **ブラウザの WebRTC が非セキュアオリジンで動くか。** 本設計は「クラウドホストの HTTPS ページ + P2P メディア」なので v1 では回避できているが、将来のオフライン LAN モード（ホスト自身が Web を配信する）の可否がここに懸かる。Safari は特に厳しい可能性が高い。
   - 回避策の候補: `*.lan.sharkpp.net` のワイルドカード DNS を RFC1918 アドレスに向け、実証明書をアプリに同梱する（Plex 方式）。証明書配布・更新の運用が発生する。
2. **macOS の Secure Input 有効時に `CGEvent` によるキー注入が届くか。** 届かない場合、リモートからパスワード入力ができないという実用上大きな制限になる。
3. **ScreenCaptureKit の `.dirtyRects` を使った送出抑制の実効性**（静止時の CPU / 帯域削減量）。

### B. 製品仕様として決めるべきこと

4. **音声を扱うか。** 要件に含まれていない。macOS 13+ / Android は システム音声をキャプチャできる。扱うなら M7 ではなく M2 相当の優先度になる可能性がある。→ **要決定**
5. **クリップボード同期。** リモート操作ソフトとしては事実上必須級。テキストのみか、画像・ファイルまで含むか。機微情報が双方向に流れるため、明示的な同期ボタン方式にするか自動同期にするかの判断も必要。→ **要決定**
6. **同時接続ビューア数。** 1:1 前提で設計している。1:N にすると simulcast または SFU が必要になり、アーキテクチャが変わる。後付けが最も高くつく箇所。→ **早期に要決定**
7. **マルチディスプレイの扱い。** 1 画面を選択して送るのか、全画面を連結して 1 ストリームにするのか、ストリームを複数張るのか。→ 選択方式を既定とする案を推奨、要承認
8. **無人アクセス（ホストの前に人がいない状態での接続）を認めるか。** 認めるなら永続的な信頼済みデバイス登録・自動承認・監査ログが必要で、セキュリティ設計が一段重くなる。→ **要決定**
9. **ファイル転送・ドラッグ&ドロップ。** 非目標としたが、需要が高い機能。DataChannel でそのまま実装できるため後付けは容易。

### C. 運用・コスト

10. **TURN サーバの要否と費用。** 対称 NAT 環境では TURN が無いと接続できない。画面配信は帯域が大きく、リレー費用が直接コストになる。無料枠を設けるか、LAN 限定を既定にするか。→ **要決定**
11. **libwebrtc ビルドの追従。** ビルド済みバイナリの供給元に依存する。供給が途絶えた場合の代替（自前ビルド）のコストを見積もっておく必要がある。
12. **アンチウイルス / EDR による誤検知。** 画面キャプチャ + 入力注入は RAT と同じ挙動であり、検知されうる。署名・notarization に加え、ベンダへのホワイトリスト申請が必要になる可能性。

### D. コンプライアンス・配布

13. **Android のアクセシビリティ API ポリシー。** Google Play は `AccessibilityService` の用途を厳しく制限している。リモート操作用途が認められるか、あるいは Play 外配布 / Shizuku 必須にするかの判断が必要。→ **M5 着手前に要調査**
14. **macOS は Mac App Store で配布できない**（Accessibility + 広範な画面収録がサンドボックスと両立しない）。Developer ID 直配布を前提とする。→ 承認事項
15. **ライセンス方針**（OSS / プロプライエタリ）。libwebrtc は BSD なので制約は少ないが、方針が未定。

### E. 設計として明示的に不足している領域

16. **エラー・切断時の挙動が未定義。** ネットワーク断、権限剥奪、ディスプレイ構成変更、スリープ復帰時に何が起きるべきか。特に **切断時にホスト画面をロックするか**は安全上重要。
17. **テスト戦略。** 画面キャプチャと入力注入は CI で検証しづらい。プロトコル層（§6）は実機なしでテストできるよう純粋な変換関数として切り出す設計が必要。E2E は macOS ランナー + ヘッドレス Chrome で M0 から用意する。
18. **観測性。** 遅延・フレームレート・ビットレート・パケットロスの計測と、ユーザに見せる接続品質表示。障害の切り分けができないと運用できない。
19. **ローカライズ。** ja / en。ホスト UI とビューア UI の両方。
20. **HiDPI と座標変換の検証。** Retina、Windows のディスプレイごとの異なるスケール、Android の density。正規化座標で吸収する設計だが、実機での丸め誤差の確認が要る。
21. **ビューアのアクセシビリティ。** 映像は本質的にスクリーンリーダで読めない。せめて操作 UI 部分の keyboard navigation と ARIA は担保する。

### F. 小さいが決めておくべき点

22. Cmd/Ctrl の入れ替え設定（Mac ビューア → Windows ホスト等のクロスプラットフォーム操作時）
23. モバイルホストの発熱・バッテリ保護（一定温度で自動的に品質を落とす／停止する閾値）
24. セルラー回線検出時の帯域上限
25. アイドルタイムアウト（無操作 N 分で自動切断）
