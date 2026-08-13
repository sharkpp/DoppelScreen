import CoreGraphics
import Foundation
import Observation
import OSLog
import WebRTC

private let log = Logger(subsystem: "net.sharkpp.doppelscreen", category: "stream")

/// ディスプレイ 1 枚ぶんの配信（SPEC.md §5.2）。
///
/// 画面ごとに URL を分けるため、キャプチャ・エンコード・PeerConnection も画面ごとに持つ。
/// 別々の画面を別々のビューアへ同時に配信できる。同じ画面に繋げるビューアは 1 台だけで、
/// 後から来たものが先客を置き換える（ビューアのリロード時に古い接続で塞がるのを避ける）。
///
/// **キャプチャはホストが承認して初めて開始する**（SPEC.md §5.2）。承認前に画面の内容が
/// 符号化されることがない、という形で無人アクセス不可を保証する。
@MainActor
@Observable
final class DisplayStream {

    /// キャプチャとビューアの状態は承認で連動するため、1 本の状態機械として持つ。
    /// 文字列はビューアの接続元アドレス
    enum State: Equatable {
        case idle
        /// ビューアが来て、ホストの承認を待っている
        case awaitingApproval(String)
        case starting(String)
        case streaming(String)
        case failed(String)
    }

    let id: CGDirectDisplayID
    private(set) var display: DisplayInfo
    private(set) var state: State = .idle
    private(set) var captureStatistics = ScreenCapturer.Statistics()
    /// 送出側の実測。1 秒ごとに更新する
    private(set) var streamStatistics: PeerTransport.Statistics?
    /// 実際に動いているキャプチャの構成。解像度追従の突き合わせに使う
    private(set) var activeConfiguration: ScreenCapturer.Configuration?
    /// ビューアが選んだ品質プリセット（SPEC.md §7.2）。接続ごとに既定へ戻す
    private(set) var quality: QualityPreset = .standard

    /// ストリームが自発的に落ちたときの通知。画面構成が変わっている可能性が高い
    var onUnexpectedStop: (@MainActor (String) -> Void)?

    private let capturer = ScreenCapturer()
    private let pipeline: VideoPipeline
    /// 再接続チケットの発行元（SPEC.md §11-4）
    private let pairing: PairingService
    private var transport: PeerTransport?
    /// 承認待ちのビューア。承認するまで WebRTC は張らない
    private var pending: SignalingConnection?
    /// 直近にビューアが申告した表示サイズ（物理ピクセル）
    private var viewport: (width: Int, height: Int)?
    /// 解像度追従のデバウンス（SPEC.md §7.1）
    private var followWork: Task<Void, Never>?
    private var statisticsTimer: Timer?
    /// キャプチャの開始・停止・再構成を直列化する。順序が入れ替わると
    /// 「UI の表示と実際に動いているストリームが食い違う」
    private var pendingWork: Task<Void, Never>?

    init(
        display: DisplayInfo,
        factory: RTCPeerConnectionFactory,
        pairing: PairingService
    ) {
        id = display.id
        self.display = display
        self.pairing = pairing
        pipeline = VideoPipeline(factory: factory, trackID: "screen-\(display.id)")

        // フレームはキャプチャ用キューから WebRTC へ直接流す。MainActor を経由させない
        capturer.setFrameHandler { [pipeline] sampleBuffer in
            pipeline.capture(sampleBuffer)
        }
        capturer.setStopHandler { [weak self] error in
            // Error を跨がせず、表示に使う文字列だけを運ぶ
            let message = error.localizedDescription
            Task { @MainActor in self?.handleUnexpectedStop(message) }
        }
    }

    var isActive: Bool {
        switch state {
        case .idle, .failed: false
        case .awaitingApproval, .starting, .streaming: true
        }
    }

    /// 解像度変更などでディスプレイの素性が変わったときに追従する
    func update(display: DisplayInfo) {
        guard display != self.display else { return }
        self.display = display
        transport?.send(.display(ControlDisplay(display)))
        scheduleResolutionFollow()
    }

    // MARK: - 接続の受け入れ

    /// ビューアが繋いできた。承認を待つ状態にするだけで、まだ何も撮らない（SPEC.md §5.2）。
    ///
    /// `resumed` は再接続チケットで通ってきた場合（SPEC.md §11-4）。**一度承認したビューアが
    /// 繋ぎ直しただけ**なので、承認をやり直さずに再開する。これがないとネットワークが
    /// 一瞬切れるたびに人がボタンを押すことになり、自動再接続が意味をなさない。
    func request(_ connection: SignalingConnection, resumed: Bool = false) {
        disconnect()
        pending = connection
        state = .awaitingApproval(connection.remoteDescription)

        // 承認を待っている間にビューアが諦めることがある
        connection.onClose { [weak self] in
            Task { @MainActor in self?.handlePendingClosed(connection) }
        }

        guard !resumed else {
            log.info("viewer resumed on display \(self.id): \(connection.remoteDescription, privacy: .public)")
            approve()
            return
        }
        log.info("viewer awaiting approval on display \(self.id): \(connection.remoteDescription, privacy: .public)")
    }

    func approve() {
        guard let connection = pending else { return }
        pending = nil
        state = .starting(connection.remoteDescription)
        enqueue { [weak self] in await self?.performStart(connection) }
    }

    func reject() {
        guard let connection = pending else { return }
        pending = nil
        connection.send(.error(code: "rejected"))
        connection.close()
        state = .idle
    }

    /// 人が「切断」を押したときと、配信をやめるときに呼ぶ。
    /// **発行済みの再接続チケットを無効にする** — 切ったつもりのビューアが黙って戻ってきてはいけない
    func disconnect() {
        pairing.revokeResumeTickets(for: id)
        followWork?.cancel()
        followWork = nil
        stopStatisticsPolling()
        pending?.close()
        pending = nil
        transport?.close()
        transport = nil
        viewport = nil
        streamStatistics = nil
        // 次に繋いでくるのは別のビューアかもしれない。プリセットは持ち越さない
        quality = .standard
        state = .idle
        enqueue { [weak self] in await self?.performStopCapture() }
    }

    /// 画面の切断やアプリ終了で呼ぶ。停止が完了するまで待てる
    func stop() async {
        disconnect()
        await pendingWork?.value
    }

    // MARK: - 配信

    private func performStart(_ connection: SignalingConnection) async {
        let configuration = configuration(width: display.pixelWidth, height: display.pixelHeight)
        do {
            try await capturer.start(configuration)
            activeConfiguration = configuration
        } catch {
            state = .failed(error.localizedDescription)
            connection.send(.error(code: "capture_failed", detail: error.localizedDescription))
            connection.close()
            return
        }

        do {
            let transport = try PeerTransport(
                factory: pipeline.factory,
                connection: connection
            ) { [weak self] id, state in
                Task { @MainActor in self?.updateTransportState(state, from: id) }
            }
            self.transport = transport

            // 制御チャネル（SPEC.md §7）。開いたら画面の素性を渡し、以降は表示サイズを受ける
            transport.onControlOpen = { [weak self] in
                Task { @MainActor in self?.sendHello() }
            }
            transport.onControl = { [weak self] message in
                Task { @MainActor in self?.handle(message) }
            }

            try await transport.start(track: pipeline.track, quality: quality)
            startStatisticsPolling()
        } catch {
            state = .failed(error.localizedDescription)
            await performStopCapture()
        }
    }

    /// 既に切った接続からの通知は捨てる。古い「切断しました」で新しい接続を塗り潰さない
    private func updateTransportState(_ transportState: PeerTransport.State, from id: UUID) {
        guard let transport, transport.id == id else { return }

        switch transportState {
        case .negotiating:
            state = .starting(transport.remoteDescription)
        case .streaming:
            state = .streaming(transport.remoteDescription)
            // 表示サイズは制御チャネルの都合で先に届いていることがある
            scheduleResolutionFollow()
        case .closed(let reason):
            self.transport = nil
            state = .failed(reason)
            stopStatisticsPolling()
            streamStatistics = nil
            // ビューアが去ったら撮るのをやめる。CPU・電力・発熱に効く（SPEC.md §4.3）
            enqueue { [weak self] in await self?.performStopCapture() }
        }
    }

    private func handlePendingClosed(_ connection: SignalingConnection) {
        guard pending === connection else { return }
        pending = nil
        state = .idle
    }

    private func performStopCapture() async {
        await capturer.stop()
        activeConfiguration = nil
        captureStatistics = ScreenCapturer.Statistics()
    }

    private func handleUnexpectedStop(_ message: String) {
        state = .failed(message)
        transport?.send(.error(code: "capture_stopped", detail: message))
        transport?.close()
        transport = nil
        stopStatisticsPolling()
        activeConfiguration = nil
        onUnexpectedStop?(message)
    }

    // MARK: - 制御チャネル（SPEC.md §7）

    private func sendHello() {
        transport?.send(.hello(platform: "macos", display: ControlDisplay(display)))
        // 繋ぎ直すための使い切りチケットを渡す（SPEC.md §11-4）。
        // 接続トークンの期限とは独立させる — 長く映しているうちにトークンが回っても切れない
        transport?.send(.resume(
            ticket: pairing.issueResumeTicket(for: id),
            ttlMs: Int(pairing.resumeLifetime.components.seconds) * 1000
        ))
    }

    private func handle(_ message: ViewerControl) {
        switch message {
        case .viewport(let width, let height, _):
            viewport = (width, height)
            scheduleResolutionFollow()
        case .quality(let preset):
            applyQuality(preset)
        }
    }

    /// 品質プリセットの切り替え（SPEC.md §7.2）。
    ///
    /// 送出側（`RTCRtpSender`）とキャプチャ側の両方に当てる。上限 fps をエンコーダだけで
    /// 絞ると、撮ってから捨てるぶんの CPU と電力が無駄になる。
    /// 解像度追従（§7.1）とは独立していて、こちらは fps とビットレートだけを動かす。
    private func applyQuality(_ preset: QualityPreset) {
        guard preset != quality else { return }
        quality = preset
        transport?.apply(preset)

        guard let active = activeConfiguration, active.maximumFrameRate != preset.maxFramerate else { return }
        var desired = active
        desired.maximumFrameRate = preset.maxFramerate
        enqueue { [weak self] in
            do {
                try await self?.capturer.update(desired)
                self?.activeConfiguration = desired
                log.info("quality preset applied: \(preset.rawValue)")
            } catch {
                log.error("failed to apply quality preset: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// 過剰な追従を防ぐため 500ms のデバウンスをかける（SPEC.md §7.1）。
    /// リサイズ中は `viewport` が連続で届くため、これがないと毎回作り直すことになる
    private func scheduleResolutionFollow() {
        followWork?.cancel()
        followWork = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.followViewport()
        }
    }

    private func followViewport() async {
        guard let viewport, case .streaming = state, let active = activeConfiguration else { return }

        let size = VideoEncoding.followingSize(
            display: (display.pixelWidth, display.pixelHeight),
            viewport: viewport
        )
        guard size.width != active.width || size.height != active.height else { return }

        let desired = configuration(width: size.width, height: size.height)
        do {
            try await capturer.update(desired)
            activeConfiguration = desired
            log.info("display \(self.id) following viewport: \(size.width)x\(size.height)")
        } catch {
            log.error("failed to follow viewport: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func configuration(width: Int, height: Int) -> ScreenCapturer.Configuration {
        // 符号化できない解像度を撮っても意味がない。縮小は SCStream に任せる
        let size = VideoEncoding.encodableSize(width: width, height: height)
        return ScreenCapturer.Configuration(
            displayID: id,
            width: size.width,
            height: size.height,
            maximumFrameRate: quality.maxFramerate
        )
    }

    // MARK: - 統計

    /// フレームごとに `MainActor` へ hop すると遅延の原因になるため、1 秒ごとにまとめて読む。
    /// 同じ周期でビューアへ `stats` を流す（SPEC.md §7）
    private func startStatisticsPolling() {
        stopStatisticsPolling()
        statisticsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.pollStatistics() }
        }
    }

    private func pollStatistics() async {
        captureStatistics = capturer.currentStatistics()
        guard let transport else { return }
        let statistics = await transport.statistics()
        streamStatistics = statistics
        transport.send(.stats(
            fps: statistics.fps,
            bitrate: statistics.targetBitrateMbps * 1_000_000,
            encodeMs: statistics.encodeMs
        ))
    }

    private func stopStatisticsPolling() {
        statisticsTimer?.invalidate()
        statisticsTimer = nil
    }

    /// 直列化。前の操作が終わってから次を実行する
    private func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        let previous = pendingWork
        pendingWork = Task {
            await previous?.value
            await operation()
        }
    }
}
