import Foundation
import WebRTC

/// DataChannel `control` の送受信（SPEC.md §7）。
///
/// `RTCDataChannelDelegate` は `NSObject` を要求するため、委譲をここに閉じ込めて
/// `PeerTransport` からは通常のクロージャで扱えるようにする。
///
/// チャネルは 1 本だけ。高頻度イベントが存在しないため分ける必要がない。
final class ControlChannel: NSObject, RTCDataChannelDelegate, @unchecked Sendable {

    private let channel: RTCDataChannel

    /// ビューア側で開いた瞬間。`hello` はここから送る
    var onOpen: (@Sendable () -> Void)?
    var onMessage: (@Sendable (ViewerControl) -> Void)?

    init(channel: RTCDataChannel) {
        self.channel = channel
        super.init()
        channel.delegate = self
    }

    /// 開く前に呼ばれた分は捨てる。制御メッセージはいずれも「最新の 1 通だけが意味を持つ」
    /// 種類のもので、溜めて後から流す価値がない
    func send(_ message: HostControl) {
        guard channel.readyState == .open else { return }
        let text = ControlCodec.encodeHostControl(message)
        channel.sendData(RTCDataBuffer(data: Data(text.utf8), isBinary: false))
    }

    // MARK: - RTCDataChannelDelegate

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        guard dataChannel.readyState == .open else { return }
        onOpen?()
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard !buffer.isBinary,
              let text = String(data: buffer.data, encoding: .utf8),
              let message = ControlCodec.decodeViewerControl(text)
        else { return }
        onMessage?(message)
    }
}
