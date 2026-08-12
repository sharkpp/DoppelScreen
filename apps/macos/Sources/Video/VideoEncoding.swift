import WebRTC

/// 送出側の符号化方針（SPEC.md §2.5 / §3.2 / §7.2）。
///
/// 既定のままでは、立ち上がりの帯域推定（300kbps 級）に引きずられて解像度が
/// 1/3 まで落ちる（実測 2880×1800 → 960×600）。LAN では帯域がほぼ制約に
/// ならないため、**推定の初期値ごと潤沢に与えて量子化を浅く保つ**。
///
/// 解像度はビューアの表示サイズに追従させる（`followingSize`）。
/// 上限 fps・上限ビットレート・劣化の方向はビューアが選ぶ（`QualityPreset`、SPEC.md §7.2）。
enum VideoEncoding {

    /// 推定がここより下がらないようにする
    static let minBitrateBps = 5_000_000

    /// H.264 level 5.2 の最大フレームサイズ（マクロブロック数）。
    /// 3840×2160 は覆うが、5K（5120×2880）や 6K のディスプレイは超える。
    /// **超えたまま渡すと VideoToolbox が 1 枚も出力しない**（`H264EncoderFactory` 参照）。
    private static let maximumMacroblocks = 36864

    /// 符号化できる範囲に収めた解像度。縦横比は保つ。
    ///
    /// 縮小は `SCStream` 側で行われるため（`SCStreamConfiguration.width` / `height`）、
    /// CPU 側のスケーリングは発生しない。
    /// ここで見るのは level の上限だけ。表示サイズへの追従は `followingSize`。
    static func encodableSize(width: Int, height: Int) -> (width: Int, height: Int) {
        let macroblocks = ((width + 15) / 16) * ((height + 15) / 16)
        guard macroblocks > maximumMacroblocks else { return (width, height) }

        let scale = (Double(maximumMacroblocks) / Double(macroblocks)).squareRoot()
        return (even(Double(width) * scale), even(Double(height) * scale))
    }

    /// 追従先の段階（高さ）。SPEC.md §7.1 の 720p / 1080p / 1440p / 2160p
    static let resolutionSteps = [720, 1080, 1440, 2160]

    /// ビューアの表示サイズに追従した符号化解像度（SPEC.md §7.1）。
    ///
    /// 表示先の物理ピクセル数を超える解像度を送っても、エンコード時間（＝遅延）と帯域を
    /// 捨てるだけで何も得られない。M1 の実測では**エンコードだけがバジェットを超過し、
    /// 支配要因は解像度だった**（docs/STACK.md §2.11）。ここが最大の遅延削減策になる。
    ///
    /// 実解像度にぴったり合わせず段階的な値へ丸めるのは、ウィンドウのリサイズのたびに
    /// エンコーダの再構成とキーフレームが走るのを防ぐため。
    /// ビューアはアスペクト比を保ってレターボックス表示する（SPEC.md §8.2）ので、
    /// 実際に使われる画素数は長辺ではなく「はみ出さない側」で決まる。
    static func followingSize(
        display: (width: Int, height: Int),
        viewport: (width: Int, height: Int)
    ) -> (width: Int, height: Int) {
        let native = encodableSize(width: display.width, height: display.height)
        guard viewport.width > 0, viewport.height > 0, native.width > 0, native.height > 0 else {
            return native
        }

        let scale = min(
            Double(viewport.width) / Double(native.width),
            Double(viewport.height) / Double(native.height)
        )
        let wanted = Double(native.height) * scale

        // 直近上位の段階。ディスプレイの実解像度を超える段階には意味がない
        guard let step = resolutionSteps.first(where: { Double($0) >= wanted }), step < native.height else {
            return native
        }
        return (even(Double(native.width) * Double(step) / Double(native.height)), step)
    }

    /// 4:2:0 は偶数の幅・高さを要求する
    private static func even(_ value: Double) -> Int {
        max(2, Int(value * 0.5) * 2)
    }

    /// 帯域推定そのものの範囲。`currentBitrateBps` は推定値を**その場で強制する**ため、
    /// 立ち上がりのランプアップと、それに伴う初期のダウンスケールが起きなくなる。
    static func apply(_ preset: QualityPreset, to peer: RTCPeerConnection) {
        peer.setBweMinBitrateBps(
            NSNumber(value: minBitrateBps),
            // 上限から始めさせる。低い値から探らせると、その間だけ解像度が落ちる
            currentBitrateBps: NSNumber(value: preset.maxBitrateBps),
            maxBitrateBps: NSNumber(value: preset.maxBitrateBps)
        )
    }

    /// 上限 fps・上限ビットレート・劣化の方向をプリセットから当てる（SPEC.md §7.2）。
    /// 送出中に呼び直せる — ビューアがプリセットを変えたときの反映経路でもある。
    static func apply(_ preset: QualityPreset, to sender: RTCRtpSender) {
        let parameters = sender.parameters
        parameters.degradationPreference = NSNumber(value: preset.degradationPreference.rawValue)
        for encoding in parameters.encodings {
            encoding.maxBitrateBps = NSNumber(value: preset.maxBitrateBps)
            encoding.minBitrateBps = NSNumber(value: minBitrateBps)
            encoding.maxFramerate = NSNumber(value: preset.maxFramerate)
            // 実装既定のスケーリングに任せない。キャプチャした解像度をそのまま送る
            encoding.scaleResolutionDownBy = 1
        }
        sender.parameters = parameters
    }
}
