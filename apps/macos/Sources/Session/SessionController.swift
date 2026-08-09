import CoreGraphics
import Foundation
import Observation

/// アプリ全体の状態機械（SPEC.md §2.3）。
/// M0 の時点ではキャプチャのライフサイクルと権限状態のみを持つ。
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
    private(set) var displays: [DisplayInfo] = []
    private(set) var captureState: CaptureState = .idle
    private(set) var statistics = ScreenCapturer.Statistics()

    var selectedDisplayID: CGDirectDisplayID? {
        didSet {
            guard selectedDisplayID != oldValue, captureState == .running else { return }
            Task { await restartCapture() }
        }
    }

    let capturer = ScreenCapturer()
    let previewRenderer = PreviewRenderer()

    private var statisticsTimer: Timer?

    var selectedDisplay: DisplayInfo? {
        displays.first { $0.id == selectedDisplayID }
    }

    init() {
        // フレームはキャプチャ用キューからプレビューへ直接流す。MainActor を経由させない
        capturer.setFrameHandler { [previewRenderer] sampleBuffer in
            previewRenderer.enqueue(sampleBuffer)
        }
    }

    // MARK: - 権限

    func refreshPermission() {
        permissionGranted = ScreenRecordingPermission.isGranted
    }

    func requestPermission() {
        ScreenRecordingPermission.request()
        refreshPermission()
    }

    // MARK: - ディスプレイ

    func refreshDisplays() async {
        guard permissionGranted else { return }
        do {
            let raw = try await capturer.availableDisplays()
            displays = raw.map(DisplayNaming.decorate)
            if selectedDisplayID == nil || !displays.contains(where: { $0.id == selectedDisplayID }) {
                selectedDisplayID = displays.first?.id
            }
        } catch {
            captureState = .failed(error.localizedDescription)
        }
    }

    // MARK: - キャプチャ

    func startCapture() async {
        guard let display = selectedDisplay else { return }
        captureState = .starting
        do {
            try await capturer.start(
                ScreenCapturer.Configuration(
                    displayID: display.id,
                    width: display.pixelWidth,
                    height: display.pixelHeight
                )
            )
            captureState = .running
            startStatisticsPolling()
        } catch {
            captureState = .failed(error.localizedDescription)
        }
    }

    func stopCapture() async {
        stopStatisticsPolling()
        await capturer.stop()
        captureState = .idle
        statistics = ScreenCapturer.Statistics()
    }

    private func restartCapture() async {
        await stopCapture()
        await startCapture()
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
