import CoreGraphics
import Foundation
import NIOCore
import NIOWebSocket

/// 認証済みのビューア 1 本ぶんのシグナリング経路。
///
/// 受け取り側（`SessionController`）がハンドラを付けるより先にメッセージが届きうるため、
/// 付くまでは溜めておく。ビューアは接続直後に `hello` を送るので、この競合は普通に起きる。
final class SignalingConnection: @unchecked Sendable {

    private let channel: Channel
    private let lock = NSLock()
    private var pending: [ViewerSignal] = []
    private var signalHandler: (@Sendable (ViewerSignal) -> Void)?
    private var closeHandler: (@Sendable () -> Void)?
    private var isClosed = false

    init(channel: Channel) {
        self.channel = channel
    }

    /// 接続元。ホスト UI に出す
    var remoteDescription: String {
        channel.remoteAddress?.ipAddress ?? "unknown"
    }

    func onSignal(_ handler: @escaping @Sendable (ViewerSignal) -> Void) {
        let queued = lock.withLock { () -> [ViewerSignal] in
            signalHandler = handler
            let buffered = pending
            pending.removeAll()
            return buffered
        }
        for signal in queued { handler(signal) }
    }

    func onClose(_ handler: @escaping @Sendable () -> Void) {
        let alreadyClosed = lock.withLock { () -> Bool in
            closeHandler = handler
            return isClosed
        }
        if alreadyClosed { handler() }
    }

    func send(_ signal: HostSignal) {
        let text = SignalingCodec.encodeHostSignal(signal)
        var buffer = channel.allocator.buffer(capacity: text.utf8.count)
        buffer.writeString(text)
        let frame = WebSocketFrame(fin: true, opcode: .text, data: buffer)
        channel.writeAndFlush(frame, promise: nil)
    }

    func close() {
        channel.close(promise: nil)
    }

    // MARK: - パイプラインからの通知

    fileprivate func deliver(_ signal: ViewerSignal) {
        let handler = lock.withLock { () -> (@Sendable (ViewerSignal) -> Void)? in
            guard let signalHandler else {
                pending.append(signal)
                return nil
            }
            return signalHandler
        }
        handler?(signal)
    }

    fileprivate func notifyClosed() {
        let handler = lock.withLock { () -> (@Sendable () -> Void)? in
            guard !isClosed else { return nil }
            isClosed = true
            return closeHandler
        }
        handler?()
    }
}

// MARK: - WebSocket フレームの捌き

/// 認証（`hello` のトークン照合）を通ったものだけを `onAuthenticated` で外へ渡す。
/// トークンが違えば理由を返して即切る（SPEC.md §5.2）。
///
/// 照合そのものは `PairingService` が持つ（期限・失敗回数・レート制限）。ここは
/// 「WebSocket のフレームを渡して、返ってきた判定どおりに切る」だけを受け持つ。
///
/// `hello` はビューアが開いた URL が指す画面（`?d=`）も運ぶ。振り分けは受け取り側に任せる。
final class SignalingHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    /// 認証を通ったビューア。振り分けと承認の要否を受け取り側が決める材料になる
    struct Admission: Sendable {
        var display: CGDirectDisplayID?
        /// 再接続チケットで通った。承認済みとして扱ってよい（SPEC.md §11-4）
        var resumed: Bool
    }

    private let pairing: PairingService
    private let onAuthenticated: @Sendable (SignalingConnection, Admission) -> Void
    private var connection: SignalingConnection?
    private var authenticated = false

    init(
        pairing: PairingService,
        onAuthenticated: @escaping @Sendable (SignalingConnection, Admission) -> Void
    ) {
        self.pairing = pairing
        self.onAuthenticated = onAuthenticated
    }

    func handlerAdded(context: ChannelHandlerContext) {
        connection = SignalingConnection(channel: context.channel)
    }

    func channelInactive(context: ChannelHandlerContext) {
        connection?.notifyClosed()
        connection = nil
        context.fireChannelInactive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .connectionClose:
            context.close(promise: nil)
        case .ping:
            var payload = frame.unmaskedData
            let pong = WebSocketFrame(fin: true, opcode: .pong, data: payload.readSlice(length: payload.readableBytes) ?? payload)
            context.writeAndFlush(wrapOutboundOut(pong), promise: nil)
        case .text:
            var payload = frame.unmaskedData
            guard let text = payload.readString(length: payload.readableBytes) else { return }
            handle(text, context: context)
        default:
            break
        }
    }

    private func handle(_ text: String, context: ChannelHandlerContext) {
        guard let connection else { return }
        guard let signal = SignalingCodec.decodeViewerSignal(text) else { return }

        guard authenticated else {
            guard case .hello(let presented, let display, let resume) = signal else {
                reject(with: "invalid_token", context: context)
                return
            }

            // 一度承認されたビューアの繋ぎ直し。接続トークンの期限とは独立している
            // （長く映しているうちにトークンが回っても切れないようにするため）
            if let resume, pairing.redeemResumeTicket(resume, for: display) {
                authenticated = true
                onAuthenticated(connection, Admission(display: display, resumed: true))
                return
            }

            let verdict = pairing.verify(presented, from: connection.remoteDescription)
            guard let code = verdict.errorCode else {
                authenticated = true
                onAuthenticated(connection, Admission(display: display, resumed: false))
                return
            }
            reject(with: code, context: context)
            return
        }

        connection.deliver(signal)
    }

    /// 理由を届けてから切る。`channel` 経由で送ると close が先着して届かない
    private func reject(with code: String, context: ChannelHandlerContext) {
        let channel = context.channel
        write(.error(code: code), context: context)
            .whenComplete { _ in channel.close(promise: nil) }
    }

    private func write(_ signal: HostSignal, context: ChannelHandlerContext) -> EventLoopFuture<Void> {
        let text = SignalingCodec.encodeHostSignal(signal)
        var buffer = context.channel.allocator.buffer(capacity: text.utf8.count)
        buffer.writeString(text)
        return context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .text, data: buffer)))
    }
}
