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
/// `hello` はビューアが開いた URL が指す画面（`?d=`）も運ぶ。振り分けは受け取り側に任せる。
final class SignalingHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let token: String
    private let onAuthenticated: @Sendable (SignalingConnection, CGDirectDisplayID?) -> Void
    private var connection: SignalingConnection?
    private var authenticated = false

    init(token: String, onAuthenticated: @escaping @Sendable (SignalingConnection, CGDirectDisplayID?) -> Void) {
        self.token = token
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
            guard case .hello(let presented, let display) = signal, presented == token else {
                // 理由を届けてから切る。`channel` 経由で送ると close が先着して届かない
                let channel = context.channel
                write(.error(message: "接続トークンが正しくありません"), context: context)
                    .whenComplete { _ in channel.close(promise: nil) }
                return
            }
            authenticated = true
            onAuthenticated(connection, display)
            return
        }

        connection.deliver(signal)
    }

    private func write(_ signal: HostSignal, context: ChannelHandlerContext) -> EventLoopFuture<Void> {
        let text = SignalingCodec.encodeHostSignal(signal)
        var buffer = context.channel.allocator.buffer(capacity: text.utf8.count)
        buffer.writeString(text)
        return context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .text, data: buffer)))
    }
}
