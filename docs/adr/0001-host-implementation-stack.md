# ADR 0001: ホスト実装を Dart/Flutter で共通化するか

- **状態**: **却下**（Flutter 案を採らない）
- **決定日**: 2026-08-09（起案 2026-08-08）
- **関連**: [SPEC.md](../../SPEC.md), [docs/STACK.md](../STACK.md)

## 決定

**Dart/Flutter による共通化は行わない。[docs/STACK.md](../STACK.md) のネイティブ実装案で確定する。**

維持者の判断による。本文の分析のうち、この判断を支える材料は以下:

- Flutter が削減できるのは中〜低難度の領域のみで、本プロジェクトの難所であるキャプチャと遅延制御は 4 実装のまま残る（§1）
- iOS は Broadcast Extension のメモリ制約により Flutter 化できず、共通化の効果が構造的に目減りする（§3.2）
- 効果が出るのは M3 以降であり、M0〜M2 の間は共有相手のいない抽象境界にしかならない（§3.7）

**§5 のスパイクは実施不要**。以下は本 ADR の結論とは独立に有効であり、[docs/STACK.md](../STACK.md) 側で維持される:

- iOS Broadcast Upload Extension は完全ネイティブ（§4-3）
- Web ビューアは TypeScript であり Flutter Web にしない（§4-4）

以下は却下された案の検討記録である。**同じ議論を繰り返さないために残す。**

---

## 背景

[docs/STACK.md](../STACK.md) の現行案は、ホストを 4 プラットフォームすべてネイティブ実装する（Swift / C++ WinRT / Kotlin / Swift）。共有するのはワイヤプロトコルと Web ビューアのみ。

これに対し、大部分を Dart/Flutter で実装する案を検討する。

---

## 1. 何が共有できて、何ができないか

実装領域ごとの「必要な実装数」を比較する。これが判断の土台になる。

| 領域 | 難度 | ネイティブ案 | Flutter 案 |
| --- | --- | --- | --- |
| **画面キャプチャ** | **高** | 4 | **4（変わらない）** |
| **WebRTC 統合・エンコーダ制御** | **高** | 4 | 1（flutter_webrtc に依存）または 4（自前チャネル） |
| LocalServer + TLS + 証明書生成 | 中 | 3（NIO を macOS/iOS で共用） | 2（Dart + iOS Extension） |
| UI・権限オンボーディング・ペアリング・QR・セッション管理 | 中 | 3 | **1** |
| プロトコル codec（ホスト側） | 低 | 3 | **1** |

**要点: Flutter が削るのは「中〜低難度で 3〜4 重複している領域」であり、「高難度の領域」は 1 つも削れない。**

キャプチャは ScreenCaptureKit / Windows.Graphics.Capture / MediaProjection / ReplayKit を叩く以外に方法がなく、どちらの案でも 4 実装が必要。本プロジェクトで最も難しく、最も遅延に効く部分がまるごと共有対象外になる。

---

## 2. メリット

### 2.1 UI とアプリロジックの実装数が 3 → 1 になる

もっとも大きい効果。SwiftUI + WinUI 3 + Jetpack Compose の 3 実装が 1 つになる。対象は権限オンボーディング、QR / URL 表示、接続承認フロー、ディスプレイ選択、品質プリセット、統計表示、切断ボタン、エラー表示。

地味だが量が多く、4 プラットフォームで挙動を揃えるのが面倒な領域でもある。UI の不整合バグが構造的に発生しなくなる価値は小さくない。

### 2.2 LocalServer が Dart 標準ライブラリだけで書ける

`dart:io` に必要なものが揃っている。外部パッケージがほぼ不要。

```dart
// HTTP と HTTPS を同じハンドラで 2 本立てる（SPEC.md §5.3）
final http  = await HttpServer.bind(InternetAddress.anyIPv4, 8422);
final https = await HttpServer.bindSecure(InternetAddress.anyIPv4, 8423, securityContext);

// WebSocket アップグレードも標準
if (WebSocketTransformer.isUpgradeRequest(req)) {
  final ws = await WebSocketTransformer.upgrade(req);
}

// LAN IP の列挙も標準・クロスプラットフォーム
final ips = await NetworkInterface.list(type: InternetAddressType.IPv4);
```

ネイティブ案では SwiftNIO / Boost.Beast / Ktor の 3 つを扱うことになる。とくに **Windows の Boost.Beast が消えるのは実質的な負担減**。

### 2.3 開発チームの習熟度

本プロジェクトの維持者は Flutter を日常的に使っている。**長期的な保守性は「言語として優れているか」ではなく「維持する人が流暢か」で決まる。** C++/WinRT と Kotlin と Swift を並行して面倒を見る負荷は、一人〜少人数のプロジェクトでは無視できない。

AGENTS.md の「アーキテクチャ上の判断は長期で行う」に照らすと、この要素は技術的優劣と同等の重みを持つ。

### 2.4 ホットリロード

UI とセッション状態遷移の試行錯誤が速くなる。オンボーディングや接続フローのように「実際に触らないと良し悪しが分からない」部分で効く。

---

## 3. デメリットとリスク

### 3.1 【最大の懸念】メディア経路の制御を手放す可能性

本プロジェクトの唯一の価値は遅延。その遅延はキャプチャ〜エンコード〜送出の経路で決まる。**Flutter を選ぶと、この経路に `flutter_webrtc` という community パッケージが挟まる。**

具体的に必要で、パッケージが提供しているか不明な機能:

| 必要な制御 | 根拠 | 提供状況 |
| --- | --- | --- |
| ネイティブでキャプチャしたフレームをトラックへ注入 | ScreenCaptureKit を使うため（STACK.md §2.2） | **要検証。公開 API では期待できない** |
| `VideoEncoderFactory` の差し替え | Windows の MF ハードウェアエンコーダ登録に必須（STACK.md §3） | **要検証。おそらく不可** |
| `RTCRtpSender.setParameters`（maxBitrate / maxFramerate / degradationPreference） | 品質プリセット（SPEC.md §7.2） | 要検証 |
| `contentHint` | 同上 | 要検証 |

パッケージが対応していない場合、フォークするか、パッチを当て続けるか、自前チャネルに切り替えることになる。**依存の底が抜けたときの退避コストが高い。**

### 3.2 【構造的制約】iOS は Flutter にできない

Broadcast Upload Extension のメモリ上限は約 50MB。**Flutter エンジンをこの中で動かすのは現実的でない。** Extension は PeerConnection と LocalServer を保持する必要があるため（コンテナアプリは suspend される）、**iOS のホスト機能は全面的に Swift ネイティブになる。**

結果として:
- Flutter が担えるのは iOS では「コンテナアプリの起動画面」のみ
- LocalServer は Dart 版と Swift 版の 2 実装になる（3 → 2 であって 3 → 1 ではない）

§2.2 のメリットは、この分だけ目減りする。

### 3.3 macOS のメニューバー常駐が Flutter の流儀に合わない

SPEC.md はメニューバー常駐（`MenuBarExtra`）を前提にしている。Flutter デスクトップの基本単位はウィンドウであり、`NSStatusItem` + `NSPopover` の中に Flutter ビューを置くのは正攻法ではない。`tray_manager` 等でトレイアイコンとメニューは出せるが、**リッチなポップオーバー UI を作ろうとすると AppKit の糊付けコードが必要になり、「UI を 1 実装にする」というメリットを削る。**

代替は「トレイアイコン + 小さな通常ウィンドウ」に UX を寄せること。許容できるかは判断次第。

### 3.4 フレームが Dart 側に入ると設計が壊れる

STACK.md §2.2 の要件は「CPU 側でピクセルをコピーしない」。**もしフレームがプラットフォームチャネル経由で Dart VM に入ると、コピーが発生し、GC の影響を受け、遅延バジェット（SPEC.md §3.1）が崩壊する。**

これは回避可能だが、**設計上の鉄則として明文化し、逸脱を許さない運用が必要**になる。境界を跨ぐ設計は、跨いではいけないものが跨ぎやすい。

### 3.5 遅延プロファイリングが難しくなる

Instruments / ETW でキャプチャ〜エンコードを追うとき、Dart/ネイティブ境界を挟むと計測が分断される。M1 の「glass-to-glass 60ms 以下を実測で達成」という目標に対して、原因究明のコストが上がる。

### 3.6 証明書生成の足場が弱い

ネイティブ案では `apple/swift-certificates`（Apple 公式）と Ktor 公式ユーティリティが使える。Dart では SAN 付き自己署名証明書の生成を community パッケージ（`basic_utils` 等）に頼ることになる。**要検証**。IP を SAN に入れる要件（SPEC.md §5.3）を満たせるかを確認しないと選べない。

### 3.7 メリットが M3 以降にしか出ない

M0〜M2 は macOS のみ。**この間、Flutter は「共有相手のいない抽象境界」でしかなく、純粋にオーバーヘッド。** 効果が出るのは Windows（M3）以降。

一方で AGENTS.md の「あとで差し替える前提の暫定案を採らない」により、**M0 をネイティブで作って M3 で Flutter に移す、という段階的移行は取れない。それは書き直しである。** つまりこの判断は今下す必要があり、実質的に「M3〜M5 に到達する見込みへの賭け」になる。

---

## 4. Flutter を選ぶ場合の設計上の鉄則

1. **フレームは決して Dart に入れない。** キャプチャからエンコード、WebRTC トラックまではネイティブ内で完結させる。Dart が触ってよいのは「開始／停止／解像度変更」の指示と統計値のみ。
2. **`flutter_webrtc` に送信経路を委ねない。** libwebrtc への薄い自前プラットフォームチャネルを持つ。境界を跨ぐのは SDP / ICE の文字列と制御指示だけで、頻度も量も小さい。これによりエンコーダファクトリの差し替えとフレーム注入の自由を保つ。
   - ただし §5 のスパイクで `flutter_webrtc` の内蔵画面キャプチャが遅延要件を満たすと判明した場合は、この限りではない（大幅な近道になる）。
3. **iOS Broadcast Upload Extension は完全にネイティブ。** Flutter を持ち込まない。LocalServer も Swift で実装する。
4. **Web ビューアは Flutter Web にしない。** 低遅延の映像表示面に Flutter Web のレンダリングパイプラインを挟む理由がない。TypeScript を維持する（SPEC.md §8）。

---

## 5. 判断に必要なスパイク（**却下により実施不要**）

以下は Flutter 案を検討する場合に必要だったもの。**却下したため実施しない。**

1. **`flutter_webrtc` の内蔵画面キャプチャ（`getDisplayMedia`）で macOS → ブラウザを繋ぎ、glass-to-glass を実測する。**
   - 60ms 前後に収まるなら、ホスト実装がほぼ丸ごと Flutter で済む可能性がある。**最大の近道。**
   - 収まらない場合、libwebrtc のデスクトップキャプチャが ScreenCaptureKit を使っているか、CPU で BGRA→I420 変換していないかを確認する。原因が構造的なら §4-2 の自前チャネル案へ。
2. **`flutter_webrtc` が `RTCRtpSender.setParameters` / `contentHint` を公開しているか**をコードで確認する。
3. **Dart で SAN に IP を含む自己署名証明書を生成し、`SecurityContext` に載せて iPad Safari から接続できるか**を確認する。
4. **macOS でトレイ常駐 Flutter アプリの体裁**（`tray_manager` + 小ウィンドウ）を試し、UX として許容できるか判断する。

---

## 6. 起案時点の暫定的な見解（**記録**）

起案時は「スパイク 1 の結果次第で結論が変わる」としていた。その後、スパイクを実施せず Flutter 案を却下する判断が下された（冒頭「決定」を参照）。

**再検討の条件**: 本 ADR を蒸し返すのは、以下のいずれかが起きた場合に限る。

- Windows / Android のホスト実装（M3 / M4）で、UI とアプリロジックの重複が想定を大きく超えて負担になった場合
- ネイティブ 4 実装の維持が現実的に回らないと判明した場合

いずれの場合も、M0〜M2 で macOS ネイティブ実装が完成した後の話であり、**そこからの移行は書き直しになる**という §3.7 の指摘は変わらない。
