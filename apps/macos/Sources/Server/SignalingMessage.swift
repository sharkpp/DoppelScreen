import CoreGraphics
import Foundation

/// シグナリング（WebSocket `/signal`）で流すメッセージ。
/// SPEC.md §7 の制御チャネル（DataChannel）とは別物で、こちらは接続確立にだけ使う。
///
/// エンコード／デコードは純粋関数として切り出し、実機なしでテストできる形にする
/// （docs/STACK.md §6.3）。`apps/web/src/signaling/messages.ts` と対になっている。

/// ホスト → ビューア
enum HostSignal: Sendable, Equatable {
    case offer(sdp: String)
    case candidate(IceCandidate)
    /// 理由は**コード**で送る。文言はビューアが自分の言語で出す — ビューアを見ている人の
    /// 言語がホストの言語とは限らない（SPEC.md §11-7）。`detail` は OS 由来の説明など、
    /// コードにできない補足だけに使う
    case error(code: String, detail: String? = nil)
}

/// ビューア → ホスト
enum ViewerSignal: Sendable, Equatable {
    /// 最初の 1 通。トークンと、URL が指す画面（`?d=`）をここで運ぶ（SPEC.md §5.2）。
    /// 画面が省略された場合は、ホストが主画面を選ぶ。
    ///
    /// `resume` は一度承認されたビューアが繋ぎ直すときのチケット（SPEC.md §11-4）。
    /// 通れば接続トークンの照合とホスト承認をどちらも省く
    case hello(token: String, display: CGDirectDisplayID?, resume: String? = nil)
    case answer(sdp: String)
    case candidate(IceCandidate)
}

struct IceCandidate: Sendable, Equatable {
    var candidate: String
    var sdpMid: String?
    var sdpMLineIndex: Int32?
}

enum SignalingCodec {

    /// 解釈できないものは `nil` を返して黙って捨てる。
    /// 版の食い違いで未知のメッセージが来ても接続を落とさない。
    static func decodeViewerSignal(_ text: String) -> ViewerSignal? {
        guard let object = jsonObject(text), let type = object["t"] as? String else { return nil }
        switch type {
        case "hello":
            guard let token = object["token"] as? String else { return nil }
            return .hello(
                token: token,
                display: (object["display"] as? NSNumber)?.uint32Value,
                resume: object["resume"] as? String
            )
        case "answer":
            guard let sdp = object["sdp"] as? String else { return nil }
            return .answer(sdp: sdp)
        case "candidate":
            guard let candidate = decodeCandidate(object) else { return nil }
            return .candidate(candidate)
        default:
            return nil
        }
    }

    static func encodeHostSignal(_ signal: HostSignal) -> String {
        let object: [String: Any] = switch signal {
        case .offer(let sdp):
            ["t": "offer", "sdp": sdp]
        case .candidate(let candidate):
            [
                "t": "candidate",
                "candidate": candidate.candidate,
                "sdpMid": candidate.sdpMid as Any? ?? NSNull(),
                "sdpMLineIndex": candidate.sdpMLineIndex as Any? ?? NSNull(),
            ]
        case .error(let code, let detail):
            ["t": "error", "code": code, "detail": detail as Any? ?? NSNull()]
        }

        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8)
        else { return #"{"t":"error","code":"encode_failed"}"# }
        return text
    }

    private static func decodeCandidate(_ object: [String: Any]) -> IceCandidate? {
        guard let candidate = object["candidate"] as? String else { return nil }
        return IceCandidate(
            candidate: candidate,
            sdpMid: object["sdpMid"] as? String,
            sdpMLineIndex: (object["sdpMLineIndex"] as? NSNumber)?.int32Value
        )
    }

    private static func jsonObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }
}
