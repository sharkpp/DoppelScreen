import WebRTC

/// H.264 だけを提供するエンコーダファクトリ（SPEC.md §2.5）。
///
/// **libwebrtc 既定の `RTCDefaultVideoEncoderFactory` は使えない。**
/// 既定は H.264 を level 3.1（`640c1f` / `42e01f`）として広告し、`RTCVideoEncoderH264` は
/// ネゴシエートされた level をそのまま VideoToolbox の `ProfileLevel` に渡す。
/// **VideoToolbox は level の制限（最大フレームサイズと最大ビットレート）を実際に強制し、
/// 超えると 1 枚も出力しない**（`encode` が最初のフレームで -1 を返し、以後無音で落ち続ける）。
///
/// 実測（macOS 15.5 / Apple Silicon、上限 40Mbps）:
///
/// | 解像度 | 3.0–3.2 | 4.0–4.2 | 5.0 以上 |
/// | --- | --- | --- | --- |
/// | 1920×1080 (8160MB) | ✗ | ✓ | ✓ |
/// | 2880×1800 (20340MB) | ✗ | ✗ | ✓ |
///
/// libwebrtc はこの失敗をコーデックの切り替えで隠すため、症状は
/// **「H.264 のつもりで VP8 のソフトウェア符号化が流れている」**になる。
/// ハードウェアエンコードもハードウェアデコードも効かなくなり、遅延設計（SPEC.md §3.1）が崩れる。
///
/// 対処は 2 つ:
///
/// - **level 5.2 を広告する。** 4K60 と 40Mbps を覆う
/// - **ネゴシエートされた level を無視して符号化する。** level はビューアの answer で
///   下げられる（Chrome も libwebrtc も 3.1 を返す）。`level-asymmetry-allowed=1` により
///   送出側は自分の level を使ってよく、復号側が見るのはビットストリーム中の SPS であって
///   SDP ではない
///
/// H.264 以外は広告しない。失敗が静かなコーデック切り替えに化けず、そのまま表面化する。
final class H264EncoderFactory: NSObject, RTCVideoEncoderFactory {

    /// level 5.2。最大フレームサイズ 36864 マクロブロック（4K を覆う）、
    /// High Profile の最大ビットレート 240Mbps
    static let level = "34"

    /// High（CABAC が使える。文字の可読性で効く）を先に、
    /// High を復号できないビューアのために Constrained Baseline を後ろに置く。
    private static let profiles = ["640c", "42e0"]

    func supportedCodecs() -> [RTCVideoCodecInfo] {
        Self.profiles.map(Self.codec)
    }

    /// ネゴシエート済みの `info` からは profile だけを引き継ぎ、level は自分のものを使う。
    func createEncoder(_ info: RTCVideoCodecInfo) -> RTCVideoEncoder? {
        let profile = info.parameters["profile-level-id"]?.prefix(4)
            .description ?? Self.profiles[0]
        return RTCVideoEncoderH264(codecInfo: Self.codec(profile: profile))
    }

    private static func codec(profile: String) -> RTCVideoCodecInfo {
        RTCVideoCodecInfo(
            name: kRTCVideoCodecH264Name,
            parameters: [
                "profile-level-id": profile + level,
                "level-asymmetry-allowed": "1",
                "packetization-mode": "1",
            ]
        )
    }
}
