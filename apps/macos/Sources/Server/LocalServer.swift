import CoreGraphics
import Foundation
import Network
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

    // `SecIdentity` が `Sendable` でないため struct 自体も `Sendable` にしない。
    // 待受の起動時にしか使わず、スレッドを跨がせない
    struct Configuration {
        var preferredPort: Int = 8422
        var preferredSecurePort: Int = 8423
        var token: String
        /// HTTPS 側の証明書。用意できなければ HTTP だけで待ち受ける
        var identity: SecIdentity?
    }

    /// 実際に確保できたポート。希望のポートが埋まっていればずれる
    struct Listening: Sendable, Equatable {
        var port: Int
        var securePort: Int?
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
    private var channels: [Channel] = []

    /// HTTP と HTTPS を同時に待ち受ける（SPEC.md §5.3）。扱いに差は設けず、同じハンドラを共有する。
    /// 希望のポートが使われていたら空きポートへずらす。URL / QR には戻り値を使う。
    ///
    /// `onConnection` は認証を通ったビューアが接続したときに、ネットワーク側のスレッドから呼ばれる。
    /// 第 2 引数はビューアが開いた URL が指す画面（SPEC.md §5.2）。
    @discardableResult
    func start(
        _ configuration: Configuration,
        onConnection: @escaping @Sendable (SignalingConnection, CGDirectDisplayID?) -> Void
    ) async throws -> Listening {
        await stop()

        let html = try Self.loadViewerPage()
        let token = configuration.token

        // HTTPS のポートは HTML に埋め込まず `/config` で答える。
        // 「ホストはビルド済みの 1 ファイルしか知らない」という前提を崩さない
        let ports = ResolvedPorts()

        func makeBootstrap(secure: Bool) -> NIOTSListenerBootstrap {
            var bootstrap = NIOTSListenerBootstrap(group: group)
            if secure, let identity = configuration.identity {
                let options = NWProtocolTLS.Options()
                sec_protocol_options_set_local_identity(
                    options.securityProtocolOptions,
                    sec_identity_create(identity)!
                )
                bootstrap = bootstrap.tlsOptions(options)
            }
            return bootstrap.childChannelInitializer { channel in
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
                        ViewerPageHandler(html: html, ports: ports), name: Self.viewerPageHandlerName
                    )
                }
            }
        }

        // HTTPS を先に確保する。HTTP 側の `/config` が実ポートを答えられるようにするため
        if configuration.identity != nil {
            let secure = try await bind(makeBootstrap(secure: true), preferred: configuration.preferredSecurePort)
            ports.securePort = secure.localAddress?.port
            lock.withLock { channels.append(secure) }
        }

        let plain = try await bind(makeBootstrap(secure: false), preferred: configuration.preferredPort)
        lock.withLock { channels.append(plain) }

        let listening = Listening(
            port: plain.localAddress?.port ?? configuration.preferredPort,
            securePort: ports.securePort
        )
        log.info("local server listening on :\(listening.port) / :\(listening.securePort ?? -1)")
        return listening
    }

    /// 希望のポートが埋まっていたら空きポートへずらす（SPEC.md §5.3）
    private func bind(_ bootstrap: NIOTSListenerBootstrap, preferred: Int) async throws -> Channel {
        do {
            return try await bootstrap.bind(host: "0.0.0.0", port: preferred).get()
        } catch {
            log.notice("port \(preferred) is unavailable; falling back to an ephemeral port")
            return try await bootstrap.bind(host: "0.0.0.0", port: 0).get()
        }
    }

    func stop() async {
        let running = lock.withLock { () -> [Channel] in
            let current = channels
            channels = []
            return current
        }
        guard !running.isEmpty else { return }
        for channel in running { try? await channel.close() }
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

/// HTTPS 側のポートは、待ち受けを始めるまで分からない。
/// 両方のリスナのハンドラが参照時に読めるよう、ここに置く。
private final class ResolvedPorts: @unchecked Sendable {
    private let lock = NSLock()
    private var _securePort: Int?

    var securePort: Int? {
        get { lock.withLock { _securePort } }
        set { lock.withLock { _securePort = newValue } }
    }
}

/// `/` にビューアの単一 HTML、`/config` に HTTPS 側のポートを返す。それ以外は 404。
///
/// HTTPS の URL を HTML へ埋め込む案は採らない。ホストが成果物を書き換えることになり、
/// 「ビルド済みの 1 ファイルしか知らない」という前提が崩れる（docs/STACK.md §6.1）。
private final class ViewerPageHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let html: ByteBuffer
    private let ports: ResolvedPorts
    private var head: HTTPRequestHead?

    init(html: ByteBuffer, ports: ResolvedPorts) {
        self.html = html
        self.ports = ports
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

        var headers = HTTPHeaders()
        // HSTS は送らない。送ると HTTP 経路が恒久的に死ぬ（SPEC.md §5.3）
        headers.add(name: "Cache-Control", value: "no-store")

        let status: HTTPResponseStatus
        let body: ByteBuffer
        let contentType: String

        switch (head.method, path) {
        case (.GET, "/"), (.GET, "/index.html"):
            status = .ok
            body = html
            contentType = "text/html; charset=utf-8"
        case (.GET, "/config"):
            status = .ok
            body = ByteBuffer(string: #"{"securePort":\#(ports.securePort.map(String.init) ?? "null")}"#)
            contentType = "application/json; charset=utf-8"
        default:
            status = .notFound
            body = ByteBuffer(string: "not found")
            contentType = "text/plain; charset=utf-8"
        }

        headers.add(name: "Content-Type", value: contentType)
        headers.add(name: "Content-Length", value: String(body.readableBytes))
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
