import AppKit
import CoreGraphics
import Foundation
import Observation
import WebRTC

/// アプリ全体の状態機械（SPEC.md §2.3）。
///
/// 受け持つのは「権限」「ディスプレイの一覧」「待受」「ビューアの振り分け」まで。
/// 画面ごとの配信そのものは `DisplayStream` が持つ（SPEC.md §5.2）。
///
/// 待受の開始・停止とディスプレイ構成変更は、UI とシステムの両方から届く。
/// 順序が入れ替わると「UI の表示と実際に動いているものが食い違う」ため、
/// すべての操作を単一の直列キュー（`enqueue`）に通す。
@MainActor
@Observable
final class SessionController {

    enum ServerState: Equatable {
        case idle
        case starting
        case running
        case failed(String)
    }

    /// ビューアに渡す接続先。画面ごと・インタフェースごとに 1 件（SPEC.md §5.2）
    struct Endpoint: Identifiable, Equatable {
        var displayID: CGDirectDisplayID
        var interfaceName: String
        var url: String
        /// HTTPS 経路。証明書を用意できなかった場合は `nil`
        var secureURL: String?
        var id: String { url }
    }

    private(set) var permissionGranted: Bool = ScreenRecordingPermission.isGranted
    private(set) var hasRequestedPermissionBefore: Bool = ScreenRecordingPermission.hasRequestedBefore
    private(set) var displays: [DisplayInfo] = []
    /// 画面ごとの配信。`displays` と同じ順序で並ぶ
    private(set) var streams: [DisplayStream] = []
    /// プレビューに映す画面。配信の対象ではなく、ホスト UI の表示先を選ぶだけ
    private(set) var selectedDisplayID: CGDirectDisplayID?
    private(set) var serverState: ServerState = .idle
    private(set) var endpoints: [Endpoint] = []
    /// 実際に確保できたポート。希望の 8422 / 8423 が埋まっていればずれる
    private(set) var serverPort: Int?
    private(set) var securePort: Int?
    /// 証明書を用意できなかった理由。HTTP だけで動いている状態を UI に出す
    private(set) var certificateError: String?

    let previewRenderer = PreviewRenderer()
    /// M0 では起動ごとに固定。TTL と再生成は未実装（SPEC.md §5.2）
    let token = PairingToken.generate()

    /// エンコーダは画面をまたいで 1 つで足りる。画面ごとに作ると
    /// VideoToolbox のセッションも人数分増える
    private let factory = VideoPipeline.makeFactory()
    private let server = LocalServer()
    private var pendingWork: Task<Void, Never>?
    private var displayObservation: Task<Void, Never>?
    private var addresses: [NetworkInterface] = []

    var selectedDisplay: DisplayInfo? {
        displays.first { $0.id == selectedDisplayID }
    }

    var selectedStream: DisplayStream? {
        streams.first { $0.id == selectedDisplayID }
    }

    /// 承認待ちのビューア（SPEC.md §5.2）。ホスト UI はこれを最優先で見せる
    var approvalRequests: [DisplayStream] {
        streams.filter { if case .awaitingApproval = $0.state { true } else { false } }
    }

    var isServing: Bool { serverState == .running }

    init() {
        observeDisplayConfiguration()
    }

    // MARK: - 権限

    func refreshPermission() {
        permissionGranted = ScreenRecordingPermission.isGranted
        hasRequestedPermissionBefore = ScreenRecordingPermission.hasRequestedBefore
    }

    /// プロンプトが出せなかった場合（＝過去に一度尋ねている）は、押しても何も起きないと
    /// 分からないため、そのままシステム設定を開いて次の手を示す。
    func requestPermission() {
        let granted = ScreenRecordingPermission.request()
        refreshPermission()
        if !granted {
            ScreenRecordingPermission.openSystemSettings()
        }
    }

    // MARK: - ディスプレイ

    /// ディスプレイの接続・切断・解像度変更・配置変更で飛ぶ。
    /// ウィンドウを閉じてメニューバーだけになっても追従させたいため、UI ではなくここで購読する。
    private func observeDisplayConfiguration() {
        displayObservation = Task { [weak self] in
            let changes = NotificationCenter.default
                .notifications(named: NSApplication.didChangeScreenParametersNotification)
                .map { _ in () }
            for await _ in changes {
                self?.refreshDisplays()
            }
        }
    }

    func refreshDisplays() {
        enqueue { [weak self] in await self?.performRefreshDisplays() }
    }

    /// プレビューに映す画面を選ぶ。配信には影響しない
    func selectDisplay(_ id: CGDirectDisplayID?) {
        selectedDisplayID = id
        previewRenderer.source = id
    }

    private func performRefreshDisplays() async {
        guard permissionGranted else { return }

        do {
            displays = try await ScreenCapturer.availableDisplays().map(DisplayNaming.decorate)
        } catch {
            serverState = .failed(error.localizedDescription)
            return
        }

        // 生きている画面のストリームはそのまま使い続ける。作り直すと配信中の接続が切れる
        let removed = streams.filter { stream in !displays.contains { $0.id == stream.id } }
        streams = displays.map { display in
            if let existing = streams.first(where: { $0.id == display.id }) {
                existing.update(display: display)
                return existing
            }
            return makeStream(for: display)
        }
        for stream in removed { await stream.stop() }

        if !displays.contains(where: { $0.id == selectedDisplayID }) {
            selectDisplay(displays.first?.id)
        }
        rebuildEndpoints()
    }

    private func makeStream(for display: DisplayInfo) -> DisplayStream {
        let stream = DisplayStream(display: display, factory: factory, preview: previewRenderer)
        // 画面が落ちたときは構成が変わっている可能性が高いので一覧を取り直す
        stream.onUnexpectedStop = { [weak self] _ in self?.refreshDisplays() }
        return stream
    }

    // MARK: - 待受

    /// ビューアの受け入れを開始する。**この時点では何も撮らない** — キャプチャが始まるのは
    /// ビューアが繋いできて、ホストが承認したときだけ（SPEC.md §5.2）。
    func startServing() {
        enqueue { [weak self] in await self?.performStartServing() }
    }

    func stopServing() {
        enqueue { [weak self] in await self?.performStopServing() }
    }

    private func performStartServing() async {
        guard serverPort == nil else { return }
        serverState = .starting

        addresses = NetworkInterfaces.lanAddresses()
        // 証明書が用意できなくても配信自体は成立する。HTTP だけで続ける
        var identity: SecIdentity?
        certificateError = nil
        do {
            identity = try TLSIdentity.current(addresses: addresses.map(\.address))
        } catch {
            certificateError = error.localizedDescription
        }

        do {
            let listening = try await server.start(
                .init(token: token, identity: identity)
            ) { [weak self] connection, display in
                Task { @MainActor in self?.acceptViewer(connection, display: display) }
            }
            serverPort = listening.port
            securePort = listening.securePort
            serverState = .running
            rebuildEndpoints()
        } catch {
            let message = error.localizedDescription
            await performStopServing()
            serverState = .failed(message)
        }
    }

    private func performStopServing() async {
        for stream in streams { await stream.stop() }
        await server.stop()
        endpoints = []
        addresses = []
        serverPort = nil
        securePort = nil
        certificateError = nil
        serverState = .idle
    }

    /// 既定は HTTP。証明書の警告が出ないため、成立する環境では最良の体験になる（SPEC.md §5.3）。
    /// 対象の画面はクエリで運ぶ。ビューアはこれを `hello` に載せて送り返す
    private func rebuildEndpoints() {
        guard let port = serverPort else {
            endpoints = []
            return
        }
        endpoints = displays.flatMap { display in
            addresses.map { address in
                Endpoint(
                    displayID: display.id,
                    interfaceName: address.name,
                    url: "http://\(address.address):\(port)/?d=\(display.id)#\(token)",
                    secureURL: securePort.map { "https://\(address.address):\($0)/?d=\(display.id)#\(token)" }
                )
            }
        }
    }

    func endpoints(for displayID: CGDirectDisplayID) -> [Endpoint] {
        endpoints.filter { $0.displayID == displayID }
    }

    /// ビューアを担当の画面へ振り分ける。指定された画面が無ければ理由を返して切る
    /// （黙って別の画面を映すと、意図しない画面を配信することになる）。
    private func acceptViewer(_ connection: SignalingConnection, display requested: CGDirectDisplayID?) {
        // 画面が指定されていなければ主画面。指定されていて見つからなければ受け入れない
        let target = if let requested { streams.first { $0.id == requested } } else { streams.first }
        guard let target else {
            connection.send(.error(message: "指定された画面が見つかりません"))
            connection.close()
            return
        }
        target.request(connection)
    }
}

// MARK: - 直列化

extension SessionController {
    /// 前の操作が終わってから次を実行する
    private func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        let previous = pendingWork
        pendingWork = Task {
            await previous?.value
            await operation()
        }
    }
}
