import WebRTC

/// 送出側の符号化方針（SPEC.md §2.5 / §3.2 / §7.2）。
///
/// 既定のままでは、立ち上がりの帯域推定（300kbps 級）に引きずられて解像度が
/// 1/3 まで落ちる（実測 2880×1800 → 960×600）。LAN では帯域がほぼ制約に
/// ならないため、**推定の初期値ごと潤沢に与えて量子化を浅く保つ**。
///
/// M1 の時点では単一の設定。ビューアからの切り替え（品質プリセット）は M2。
enum VideoEncoding {

    /// 立ち上がりで使わせる推定値。低い値から探らせない
    static let startBitrateBps = 20_000_000
    /// 推定がここより下がらないようにする
    static let minBitrateBps = 5_000_000
    static let maxBitrateBps = 40_000_000
    static let maxFramerate = 60

    /// H.264 level 5.2 の最大フレームサイズ（マクロブロック数）。
    /// 3840×2160 は覆うが、5K（5120×2880）や 6K のディスプレイは超える。
    /// **超えたまま渡すと VideoToolbox が 1 枚も出力しない**（`H264EncoderFactory` 参照）。
    private static let maximumMacroblocks = 36864

    /// 符号化できる範囲に収めた解像度。縦横比は保つ。
    ///
    /// 縮小は `SCStream` 側で行われるため（`SCStreamConfiguration.width` / `height`）、
    /// CPU 側のスケーリングは発生しない。
    /// ビューアの表示サイズへの追従（SPEC.md §7.1）は M2。ここでは上限だけを見る。
    static func encodableSize(width: Int, height: Int) -> (width: Int, height: Int) {
        let macroblocks = ((width + 15) / 16) * ((height + 15) / 16)
        guard macroblocks > maximumMacroblocks else { return (width, height) }

        let scale = (Double(maximumMacroblocks) / Double(macroblocks)).squareRoot()
        // 4:2:0 は偶数の幅・高さを要求する
        let even = { (value: Double) in max(2, Int(value * 0.5) * 2) }
        return (even(Double(width) * scale), even(Double(height) * scale))
    }

    /// 帯域推定そのものの範囲。`currentBitrateBps` は推定値を**その場で強制する**ため、
    /// 立ち上がりのランプアップと、それに伴う初期のダウンスケールが起きなくなる。
    static func apply(to peer: RTCPeerConnection) {
        peer.setBweMinBitrateBps(
            NSNumber(value: minBitrateBps),
            currentBitrateBps: NSNumber(value: startBitrateBps),
            maxBitrateBps: NSNumber(value: maxBitrateBps)
        )
    }

    /// 解像度を維持し、足りなくなったら fps を落とす。ミラーリングでは文字の
    /// 可読性が最優先で、ぼけた 60fps より鮮明な 30fps の方が役に立つ（SPEC.md §7.2）。
    static func apply(to sender: RTCRtpSender) {
        let parameters = sender.parameters
        parameters.degradationPreference = NSNumber(
            value: RTCDegradationPreference.maintainResolution.rawValue
        )
        for encoding in parameters.encodings {
            encoding.maxBitrateBps = NSNumber(value: maxBitrateBps)
            encoding.minBitrateBps = NSNumber(value: minBitrateBps)
            encoding.maxFramerate = NSNumber(value: maxFramerate)
            // 実装既定のスケーリングに任せない。キャプチャした解像度をそのまま送る
            encoding.scaleResolutionDownBy = 1
        }
        sender.parameters = parameters
    }
}
