import Foundation
import NIOCore
import NIOHTTP1
import NIOTransportServices
import NIOWebSocket
import OSLog

/// ビューアページの配信とシグナリング（SPEC.md §2.3 / docs/STACK.md §2.4）。
///
/// 外部サービスを一切使わない構成の要。ホストアプリ自身がビューアの HTML を返し、
/// SDP / ICE の交換も自分で受ける。返すのはバンドル同梱の単一 HTML と `/signal` だけで、
/// ルーティングは実質 2 分岐になる（ビューアを単一 HTML に落としているため）。
final class LocalServer: @unchecked Sendable {

    struct Configuration: Sendable {
        var preferredPort: Int = 8422
        var token: String
    }

    enum ServerError: LocalizedError {
        case viewerPageMissing

        var errorDescription: String? {
            switch self {
            case .viewerPageMissing:
                "ビューアページがバンドルに含まれていません（apps/web のビルドを確認してください）"
            }
        }
    }

    private static let viewerPageHandlerName = "viewer-page"

    private let log = Logger(subsystem: "net.sharkpp.doppelscreen", category: "server")
    private let group = NIOTSEventLoopGroup()
    private let lock = NSLock()
    private var channel: Channel?

    /// 待受を開始し、実際に確保できたポートを返す。
    /// 希望のポートが使われていたら空きポートへずらす。URL / QR には戻り値を使う（SPEC.md §5.3）。
    ///
    /// `onConnection` は認証を通ったビューアが接続したときに、ネットワーク側のスレッドから呼ばれる。
    @discardableResult
    func start(
        _ configuration: Configuration,
        onConnection: @escaping @Sendable (SignalingConnection) -> Void
    ) async throws -> Int {
        await stop()

        let html = try Self.loadViewerPage()
        let token = configuration.token

        let bootstrap = NIOTSListenerBootstrap(group: group)
            .childChannelInitializer { channel in
                let upgrader = NIOWebSocketServerUpgrader(
                    // SDP は 1 フレームで届く。既定の 16KB では足りなくなりうる
                    maxFrameSize: 1 << 20,
                    shouldUpgrade: { channel, head in
                        channel.eventLoop.makeSucceededFuture(head.uri == "/signal" ? HTTPHeaders() : nil)
                    },
                    upgradePipelineHandler: { channel, _ in
                        channel.eventLoop.makeCompletedFuture {
                            try channel.pipeline.syncOperations.addHandler(
                                SignalingHandler(token: token, onAuthenticated: onConnection)
                            )
                        }
                    }
                )

                return channel.eventLoop.makeCompletedFuture {
                    // アップグレードで外れるのは NIO が入れた HTTP のハンドラだけ。
                    // 自前のハンドラは残ってしまい、`WebSocketFrame` を `HTTPServerRequestPart` として
                    // 取り出そうとしてプロセスごと落ちる。昇格したら自分で外す
                    // ハンドラ自体は `Sendable` でないため、名前で外す
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline(
                        withServerUpgrade: (
                            upgraders: [upgrader],
                            completionHandler: { context in
                                context.pipeline.removeHandler(name: Self.viewerPageHandlerName, promise: nil)
                            }
                        )
                    )
                    try channel.pipeline.syncOperations.addHandler(
                        ViewerPageHandler(html: html), name: Self.viewerPageHandlerName
                    )
                }
            }

        let channel: Channel
        do {
            channel = try await bootstrap.bind(host: "0.0.0.0", port: configuration.preferredPort).get()
        } catch {
            log.notice("port \(configuration.preferredPort) is unavailable; falling back to an ephemeral port")
            channel = try await bootstrap.bind(host: "0.0.0.0", port: 0).get()
        }

        lock.withLock { self.channel = channel }
        let port = channel.localAddress?.port ?? configuration.preferredPort
        log.info("local server listening on :\(port)")
        return port
    }

    func stop() async {
        let running = lock.withLock { () -> Channel? in
            let current = channel
            channel = nil
            return current
        }
        guard let running else { return }
        try? await running.close()
        log.info("local server stopped")
    }

    /// ビューアは Vite で単一 HTML にビルドされ、ビルドフェーズでバンドルへコピーされる
    /// （docs/STACK.md §6.1）。ホスト側はこの 1 ファイルしか知らない。
    private static func loadViewerPage() throws -> ByteBuffer {
        guard let url = Bundle.main.url(forResource: "viewer", withExtension: "html"),
              let data = try? Data(contentsOf: url)
        else { throw ServerError.viewerPageMissing }
        return ByteBuffer(bytes: data)
    }
}

// MARK: - ビューアページの配信

/// `/` にビューアの単一 HTML を返すだけのハンドラ。それ以外は 404。
private final class ViewerPageHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let html: ByteBuffer
    private var head: HTTPRequestHead?

    init(html: ByteBuffer) {
        self.html = html
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            self.head = head
        case .body:
            break
        case .end:
            guard let head else { return }
            self.head = nil
            respond(to: head, context: context)
        }
    }

    private func respond(to head: HTTPRequestHead, context: ChannelHandlerContext) {
        let path = head.uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? head.uri
        let serving = head.method == .GET && (path == "/" || path == "/index.html")

        var headers = HTTPHeaders()
        // HSTS は送らない。送ると HTTP 経路が恒久的に死ぬ（SPEC.md §5.3）
        headers.add(name: "Cache-Control", value: "no-store")

        let body = serving ? html : ByteBuffer(string: "not found")
        headers.add(name: "Content-Type", value: serving ? "text/html; charset=utf-8" : "text/plain; charset=utf-8")
        headers.add(name: "Content-Length", value: String(body.readableBytes))

        let status: HTTPResponseStatus = serving ? .ok : .notFound
        context.write(wrapOutboundOut(.head(HTTPResponseHead(version: head.version, status: status, headers: headers))), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(body))), promise: nil)

        // `ChannelHandlerContext` はイベントループに閉じていて外へ持ち出せない。
        // 閉じるのは Sendable な `Channel` 経由で行う
        let keepAlive = head.isKeepAlive
        let channel = context.channel
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            if !keepAlive { channel.close(promise: nil) }
        }
    }
}
