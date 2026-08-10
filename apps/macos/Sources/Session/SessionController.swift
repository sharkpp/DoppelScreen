import AppKit
import CoreGraphics
import Foundation
import Observation
import WebRTC

/// アプリ全体の状態機械（SPEC.md §2.3）。
/// M0 の時点ではキャプチャのライフサイクルと権限状態のみを持つ。
///
/// キャプチャの開始・停止・再構成は、UI 操作とディスプレイ構成変更の両方から届く。
/// 順序が入れ替わると「UI の表示と実際に動いているストリームが食い違う」ため、
/// すべての操作を単一の直列キュー（`enqueue`）に通す。
@MainActor
@Observable
final class SessionController {

    enum CaptureState: Equatable {
        case idle
        case starting
        case running
        case failed(String)
    }

    /// ビューア 1 本ぶんの状態。1 ホスト : 1 ビューア（SPEC.md §1.3）
    enum ViewerState: Equatable {
        case none
        case negotiating(String)
        case streaming(String)
        case failed(String)
    }

    /// ビューアに渡す接続先。インタフェースが複数あるとき用に全件持つ（SPEC.md §5.2）
    struct Endpoint: Identifiable, Equatable {
        var interfaceName: String
        var url: String
        var id: String { url }
    }

    private(set) var permissionGranted: Bool = ScreenRecordingPermission.isGranted
    private(set) var hasRequestedPermissionBefore: Bool = ScreenRecordingPermission.hasRequestedBefore
    private(set) var displays: [DisplayInfo] = []
    private(set) var selectedDisplayID: CGDirectDisplayID?
    private(set) var captureState: CaptureState = .idle
    private(set) var statistics = ScreenCapturer.Statistics()
    private(set) var endpoints: [Endpoint] = []
    /// 実際に確保できたポート。希望の 8422 が埋まっていればずれる
    private(set) var serverPort: Int?
    private(set) var viewerState: ViewerState = .none

    let capturer = ScreenCapturer()
    let previewRenderer = PreviewRenderer()
    /// M0 では起動ごとに固定。TTL と再生成は M2（SPEC.md §5.2）
    let token = PairingToken.generate()

    private let pipeline = VideoPipeline(factory: VideoPipeline.makeFactory())
    private let server = LocalServer()
    private var transport: PeerTransport?

    /// 実際に動いているストリームの構成。UI の選択と食い違ったら追従させる
    private var activeConfiguration: ScreenCapturer.Configuration?
    private var pendingWork: Task<Void, Never>?
    private var displayObservation: Task<Void, Never>?
    private var statisticsTimer: Timer?

    var selectedDisplay: DisplayInfo? {
        displays.first { $0.id == selectedDisplayID }
    }

    init() {
        // フレームはキャプチャ用キューからプレビューと WebRTC へ直接流す。MainActor を経由させない
        capturer.setFrameHandler { [previewRenderer, pipeline] sampleBuffer in
            previewRenderer.enqueue(sampleBuffer)
            pipeline.capture(sampleBuffer)
        }
        capturer.setStopHandler { [weak self] error in
            // Error を跨がせず、表示に使う文字列だけを運ぶ
            let message = error.localizedDescription
            Task { @MainActor in self?.handleUnexpectedStop(message) }
        }
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

    func selectDisplay(_ id: CGDirectDisplayID?) {
        guard id != selectedDisplayID else { return }
        selectedDisplayID = id
        enqueue { [weak self] in await self?.reconcileCapture() }
    }

    private func performRefreshDisplays() async {
        guard permissionGranted else { return }

        do {
            displays = try await capturer.availableDisplays().map(DisplayNaming.decorate)
        } catch {
            captureState = .failed(error.localizedDescription)
            return
        }

        // キャプチャ中のディスプレイが消えた場合、黙って別の画面へ切り替えると
        // 意図しない画面を映し続けることになる。停止して理由を出す
        if let active = activeConfiguration, !displays.contains(where: { $0.id == active.displayID }) {
            await performStop()
            captureState = .failed("キャプチャ中のディスプレイが切断されました")
        }

        if !displays.contains(where: { $0.id == selectedDisplayID }) {
            selectedDisplayID = displays.first?.id
        }

        await reconcileCapture()
    }

    // MARK: - キャプチャ

    func startCapture() {
        enqueue { [weak self] in
            guard let self, let display = selectedDisplay else { return }
            await performStart(configuration(for: display))
        }
    }

    func stopCapture() {
        enqueue { [weak self] in await self?.performStop() }
    }

    /// 選択中のディスプレイと、実際に動いているストリームの構成を一致させる。
    /// ディスプレイ ID が同じでも解像度が変わることがあるため、構成そのものを比較する。
    private func reconcileCapture() async {
        guard let active = activeConfiguration, let display = selectedDisplay else { return }
        let desired = configuration(for: display)
        guard desired != active else { return }
        await performStart(desired)
    }

    private func configuration(for display: DisplayInfo) -> ScreenCapturer.Configuration {
        ScreenCapturer.Configuration(
            displayID: display.id,
            width: display.pixelWidth,
            height: display.pixelHeight
        )
    }

    private func performStart(_ configuration: ScreenCapturer.Configuration) async {
        captureState = .starting
        do {
            try await capturer.start(configuration)
            try await startServerIfNeeded()
            activeConfiguration = configuration
            captureState = .running
            startStatisticsPolling()
        } catch {
            activeConfiguration = nil
            stopStatisticsPolling()
            await performStop()
            captureState = .failed(error.localizedDescription)
        }
    }

    private func performStop() async {
        stopStatisticsPolling()
        disconnectViewer()
        await server.stop()
        endpoints = []
        serverPort = nil
        await capturer.stop()
        activeConfiguration = nil
        captureState = .idle
        statistics = ScreenCapturer.Statistics()
    }

    // MARK: - 配信

    /// キャプチャが動いている間だけ待ち受ける。映すものが無い状態でビューアを受け入れない。
    /// ディスプレイの再構成では貼り直しが走るため、既に待受中なら何もしない。
    private func startServerIfNeeded() async throws {
        guard serverPort == nil else { return }

        let port = try await server.start(.init(token: token)) { [weak self] connection in
            Task { @MainActor in self?.acceptViewer(connection) }
        }
        serverPort = port
        endpoints = NetworkInterfaces.lanAddresses().map {
            Endpoint(interfaceName: $0.name, url: "http://\($0.address):\(port)/#\(token)")
        }
    }

    /// 1 ホスト : 1 ビューア。後から来たものを採り、古い方を切る
    /// （ビューアのリロード時に、閉じ切っていない古い接続で塞がるのを避ける）。
    private func acceptViewer(_ connection: SignalingConnection) {
        transport?.close()
        transport = nil

        do {
            let transport = try PeerTransport(
                factory: pipeline.factory,
                connection: connection
            ) { [weak self] id, state in
                Task { @MainActor in self?.updateViewerState(state, from: id) }
            }
            self.transport = transport
            Task {
                do {
                    try await transport.start(track: pipeline.track)
                } catch {
                    updateViewerState(.closed(error.localizedDescription), from: transport.id)
                }
            }
        } catch {
            viewerState = .failed(error.localizedDescription)
            connection.close()
        }
    }

    /// 既に切った接続からの通知は捨てる。古い「切断しました」で新しい接続を塗り潰さない
    private func updateViewerState(_ state: PeerTransport.State, from id: UUID) {
        guard let transport, transport.id == id else { return }

        switch state {
        case .negotiating:
            viewerState = .negotiating(transport.remoteDescription)
        case .streaming:
            viewerState = .streaming(transport.remoteDescription)
        case .closed(let reason):
            self.transport = nil
            viewerState = .failed(reason)
        }
    }

    func disconnectViewer() {
        transport?.close()
        transport = nil
        viewerState = .none
    }

    /// 送出側の実測。接続していなければ `nil`
    func streamStatistics() async -> PeerTransport.Statistics? {
        await transport?.statistics()
    }

    /// ストリームが自発的に落ちたときの後始末。構成が変わっている可能性が高いので一覧も取り直す。
    private func handleUnexpectedStop(_ message: String) {
        enqueue { [weak self] in
            guard let self else { return }
            stopStatisticsPolling()
            activeConfiguration = nil
            statistics = ScreenCapturer.Statistics()
            captureState = .failed(message)
            await performRefreshDisplays()
        }
    }

    /// 直列化。前の操作が終わってから次を実行する
    private func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        let previous = pendingWork
        pendingWork = Task {
            await previous?.value
            await operation()
        }
    }

    // MARK: - 統計

    /// フレームごとに `MainActor` へ hop すると遅延の原因になるため、1 秒ごとにまとめて読む。
    private func startStatisticsPolling() {
        stopStatisticsPolling()
        statisticsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.statistics = self.capturer.currentStatistics()
            }
        }
    }

    private func stopStatisticsPolling() {
        statisticsTimer?.invalidate()
        statisticsTimer = nil
    }
}
