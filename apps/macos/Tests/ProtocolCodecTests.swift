import Testing

/// シグナリング（`/signal`）と制御チャネル（SPEC.md §7）の符号化。
///
/// ビューア側の対になる実装は `apps/web/src/signaling/messages.test.ts` と
/// `apps/web/src/control.test.ts`。両側を同じ形で確かめる（SPEC.md §11-6）。
struct SignalingCodecTests {

    @Test("hello を読む")
    func decodesHello() {
        let signal = SignalingCodec.decodeViewerSignal(#"{"t":"hello","token":"abc","display":7}"#)
        #expect(signal == .hello(token: "abc", display: 7, resume: nil))
    }

    /// 通ればホストは承認をやり直さない（SPEC.md §11-4）
    @Test("再接続チケット付きの hello を読む")
    func decodesHelloWithResume() {
        let signal = SignalingCodec.decodeViewerSignal(
            #"{"t":"hello","token":"abc","display":7,"resume":"tick"}"#
        )
        #expect(signal == .hello(token: "abc", display: 7, resume: "tick"))
    }

    @Test("画面の指定がなければホストが主画面を選ぶ")
    func decodesHelloWithoutDisplay() {
        let signal = SignalingCodec.decodeViewerSignal(#"{"t":"hello","token":"abc"}"#)
        #expect(signal == .hello(token: "abc", display: nil, resume: nil))
    }

    /// 文言はビューアが自分の言語で出す（SPEC.md §11-7）
    @Test("error はコードで書く")
    func encodesErrorAsCode() {
        let text = SignalingCodec.encodeHostSignal(.error(code: "token_expired"))
        #expect(text.contains(#""code":"token_expired""#))
        #expect(!text.contains("message"))
    }

    @Test("解釈できないものは捨てる")
    func rejectsUnknown() {
        #expect(SignalingCodec.decodeViewerSignal(#"{"t":"unknown"}"#) == nil)
        #expect(SignalingCodec.decodeViewerSignal("{") == nil)
        #expect(SignalingCodec.decodeViewerSignal(#"{"t":"hello"}"#) == nil)
    }
}

struct ControlCodecTests {

    @Test("viewport を読む（SPEC.md §7.1）")
    func decodesViewport() {
        let message = ControlCodec.decodeViewerControl(#"{"t":"viewport","w":2048,"h":1536,"dpr":2}"#)
        #expect(message == .viewport(width: 2048, height: 1536, dpr: 2))
    }

    @Test("品質プリセットを読む（SPEC.md §7.2）")
    func decodesQuality() {
        #expect(ControlCodec.decodeViewerControl(#"{"t":"quality","preset":"smooth"}"#) == .quality(.smooth))
        // 知らないプリセットは当てられない。現状を壊さず捨てる
        #expect(ControlCodec.decodeViewerControl(#"{"t":"quality","preset":"crisp"}"#) == nil)
    }

    @Test("大きさが 0 以下の viewport は捨てる")
    func rejectsEmptyViewport() {
        #expect(ControlCodec.decodeViewerControl(#"{"t":"viewport","w":0,"h":100}"#) == nil)
    }

    @Test("error はコードで書く")
    func encodesErrorAsCode() {
        let text = ControlCodec.encodeHostControl(.error(code: "capture_stopped", detail: "止"))
        #expect(text.contains(#""code":"capture_stopped""#))
        #expect(text.contains(#""detail":"止""#))
    }

    @Test("resume を書く（SPEC.md §11-4）")
    func encodesResume() {
        let text = ControlCodec.encodeHostControl(.resume(ticket: "tick", ttlMs: 600_000))
        #expect(text.contains(#""ticket":"tick""#))
        #expect(text.contains(#""ttlMs":600000"#))
    }
}

/// 品質プリセット（SPEC.md §7.2）の対応表
struct QualityPresetTests {

    @Test("既定は文字の可読性を優先する")
    func standardIsSharp() {
        #expect(QualityPreset.standard == .sharp)
        #expect(QualityPreset.sharp.maxFramerate == 30)
        #expect(QualityPreset.sharp.maxBitrateBps == 20_000_000)
    }

    @Test("smooth だけは fps を優先する")
    func smoothKeepsFramerate() {
        #expect(QualityPreset.smooth.maxFramerate == 60)
        #expect(QualityPreset.smooth.maxBitrateBps == 40_000_000)
        #expect(QualityPreset.balanced.maxBitrateBps == 30_000_000)
    }

    @Test("ワイヤ上の名前は 3 つだけ")
    func wireNames() {
        #expect(QualityPreset.allCases.map(\.rawValue) == ["sharp", "balanced", "smooth"])
    }
}
