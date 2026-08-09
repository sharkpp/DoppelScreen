import AppKit
import CoreGraphics
import Foundation
import Observation

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

    private(set) var permissionGranted: Bool = ScreenRecordingPermission.isGranted
    private(set) var hasRequestedPermissionBefore: Bool = ScreenRecordingPermission.hasRequestedBefore
    private(set) var displays: [DisplayInfo] = []
    private(set) var selectedDisplayID: CGDirectDisplayID?
    private(set) var captureState: CaptureState = .idle
    private(set) var statistics = ScreenCapturer.Statistics()

    let capturer = ScreenCapturer()
    let previewRenderer = PreviewRenderer()

    /// 実際に動いているストリームの構成。UI の選択と食い違ったら追従させる
    private var activeConfiguration: ScreenCapturer.Configuration?
    private var pendingWork: Task<Void, Never>?
    private var displayObservation: Task<Void, Never>?
    private var statisticsTimer: Timer?

    var selectedDisplay: DisplayInfo? {
        displays.first { $0.id == selectedDisplayID }
    }

    init() {
        // フレームはキャプチャ用キューからプレビューへ直接流す。MainActor を経由させない
        capturer.setFrameHandler { [previewRenderer] sampleBuffer in
            previewRenderer.enqueue(sampleBuffer)
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
            activeConfiguration = configuration
            captureState = .running
            startStatisticsPolling()
        } catch {
            activeConfiguration = nil
            stopStatisticsPolling()
            captureState = .failed(error.localizedDescription)
        }
    }

    private func performStop() async {
        stopStatisticsPolling()
        await capturer.stop()
        activeConfiguration = nil
        captureState = .idle
        statistics = ScreenCapturer.Statistics()
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
