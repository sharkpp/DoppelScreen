import WebRTC

/// 品質プリセット（SPEC.md §7.2）。ビューアが選び、ホストが当てる。
///
/// LAN 前提のため上限値は潤沢に取り、実効値は libwebrtc の帯域推定に任せる。
/// プリセットが実際に変えるのは 3 つだけ。
///
/// - **上限 fps**: キャプチャ側（`SCStreamConfiguration.minimumFrameInterval`）にも当てる。
///   エンコーダだけで絞ると、撮ってから捨てるぶんの CPU と電力が無駄になる。
/// - **上限ビットレート**: 量子化の深さ。文字の可読性に効く。
/// - **劣化の方向**: 足りなくなったときに解像度と fps のどちらを削るか。
///
/// SPEC.md §7.2 の `contentHint` は当てない。`contentHint` は W3C の送出側 API で、
/// libwebrtc の Objective-C SDK には対応するプロパティがない（`RTCVideoTrack` に無い）。
/// ホストがネイティブである以上ブラウザ側からも触れないため、**`contentHint` が意図していた
/// 挙動を `degradationPreference` と上限 fps で表す**。
enum QualityPreset: String, Sendable, Equatable, CaseIterable {
    /// 文書・コード。文字の可読性優先
    case sharp
    /// 一般的な作業画面
    case balanced
    /// 動画・アニメーション
    case smooth

    /// 既定。ミラーリングの主用途は文字を読むことなので、鮮明さを優先する
    static let standard = QualityPreset.sharp

    var maxFramerate: Int {
        switch self {
        case .sharp: 30
        case .balanced, .smooth: 60
        }
    }

    var maxBitrateBps: Int {
        switch self {
        case .sharp: 20_000_000
        case .balanced: 30_000_000
        case .smooth: 40_000_000
        }
    }

    /// 解像度を維持し、足りなくなったら fps を落とす。ぼけた 60fps より鮮明な 30fps の方が
    /// 役に立つ。`smooth` だけは動きの滑らかさが目的なので逆にする
    var degradationPreference: RTCDegradationPreference {
        switch self {
        case .sharp, .balanced: .maintainResolution
        case .smooth: .maintainFramerate
        }
    }

    /// ホスト UI に出す名前
    var localizedName: String {
        switch self {
        case .sharp: L10n.Quality.sharp
        case .balanced: L10n.Quality.balanced
        case .smooth: L10n.Quality.smooth
        }
    }
}
