import CoreGraphics
import Foundation

/// 制御チャネル（SPEC.md §7）で流すメッセージ。
///
/// 映像は SRTP で流れる。DataChannel `control` はメタ情報のためだけに 1 本だけ持つ。
/// JSON、1 メッセージ 1 イベント。`apps/web/src/control.ts` と対になっている。
///
/// シグナリング（`SignalingMessage`）とは別物。あちらは接続確立にだけ使い、
/// 確立後の往復はすべてこちらを通る。

/// `hello` / `display` が運ぶ画面の素性
struct ControlDisplay: Sendable, Equatable {
    var id: CGDirectDisplayID
    var name: String
    /// 物理ピクセル単位のサイズ
    var width: Int
    var height: Int
    var scale: Double

    init(_ display: DisplayInfo) {
        id = display.id
        name = display.name
        width = display.pixelWidth
        height = display.pixelHeight
        scale = display.scaleFactor
    }
}

/// ホスト → ビューア
enum HostControl: Sendable, Equatable {
    /// 接続直後に 1 回
    case hello(platform: String, display: ControlDisplay)
    /// 解像度変更・画面構成の変化
    case display(ControlDisplay)
    /// 1 秒ごと
    case stats(fps: Double, bitrate: Double, encodeMs: Double)
    case error(code: String, message: String)
}

/// ビューア → ホスト
enum ViewerControl: Sendable, Equatable {
    /// 表示領域が変わったとき（初回・リサイズ・回転・フルスクリーン切替）。
    /// ホストはこれに合わせて符号化解像度を決める（SPEC.md §7.1）
    case viewport(width: Int, height: Int, dpr: Double)
}

enum ControlCodec {

    /// 解釈できないものは `nil` を返して黙って捨てる。
    /// 版の食い違いで未知のメッセージが来ても接続を落とさない。
    static func decodeViewerControl(_ text: String) -> ViewerControl? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["t"] as? String
        else { return nil }

        switch type {
        case "viewport":
            guard let width = (object["w"] as? NSNumber)?.intValue,
                  let height = (object["h"] as? NSNumber)?.intValue,
                  width > 0, height > 0
            else { return nil }
            return .viewport(
                width: width,
                height: height,
                dpr: (object["dpr"] as? NSNumber)?.doubleValue ?? 1
            )
        default:
            return nil
        }
    }

    static func encodeHostControl(_ message: HostControl) -> String {
        let object: [String: Any] = switch message {
        case .hello(let platform, let display):
            ["t": "hello", "platform": platform, "display": encode(display)]
        case .display(let display):
            encode(display).merging(["t": "display"]) { _, new in new }
        case .stats(let fps, let bitrate, let encodeMs):
            ["t": "stats", "fps": fps, "bitrate": bitrate, "encodeMs": encodeMs]
        case .error(let code, let message):
            ["t": "error", "code": code, "message": message]
        }

        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8)
        else { return #"{"t":"error","code":"encode_failed","message":"encode failed"}"# }
        return text
    }

    private static func encode(_ display: ControlDisplay) -> [String: Any] {
        [
            "id": display.id,
            "name": display.name,
            "w": display.width,
            "h": display.height,
            "scale": display.scale,
        ]
    }
}
