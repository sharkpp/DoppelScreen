import CoreMedia
import Foundation
import OSLog
import ScreenCaptureKit

/// 画面フレームの取得（SPEC.md §2.3）。
///
/// ScreenCaptureKit は画面が変化したときにフレームを配る。ポーリングせず、届いたものを
/// 即座に下流へ渡すことで「変化から符号化開始までの待ち」を消す（SPEC.md §4.2）。
///
/// フレームは `CVPixelBuffer` をラップしたまま流し、CPU 側でコピーしない。
/// またフレームごとに `MainActor` へ hop しない。統計は呼び出し側が任意の頻度で読む。
final class ScreenCapturer: NSObject, @unchecked Sendable {

    struct Configuration: Sendable, Equatable {
        var displayID: CGDirectDisplayID
        var width: Int
        var height: Int
        var maximumFrameRate: Int = 60
        var showsCursor: Bool = true
    }

    struct Statistics: Sendable, Equatable {
        var deliveredFrames: Int = 0
        /// `.complete` 以外（主に `.idle`）で破棄したフレーム数。静止時の抑制が効いている指標
        var droppedFrames: Int = 0
        var lastFrameSize: CGSize = .zero
    }

    enum CaptureError: LocalizedError {
        case displayNotFound(CGDirectDisplayID)

        var errorDescription: String? {
            switch self {
            case .displayNotFound(let id):
                L10n.Failure.displayNotFound(id: String(id))
            }
        }
    }

    private let log = Logger(subsystem: "net.sharkpp.doppelscreen", category: "capture")
    private let outputQueue = DispatchQueue(label: "net.sharkpp.doppelscreen.capture", qos: .userInteractive)

    private let stateLock = NSLock()
    private var stream: SCStream?
    private var frameHandler: (@Sendable (CMSampleBuffer) -> Void)?
    private var stopHandler: (@Sendable (Error) -> Void)?
    private var statistics = Statistics()

    // MARK: - 問い合わせ

    /// 接続可能なディスプレイを列挙する。名前とスケールは未解決（`DisplayNaming` で補う）。
    /// 画面ごとにキャプチャを持つため（SPEC.md §5.2）、列挙はインスタンスに紐づかない。
    static func availableDisplays() async throws -> [DisplayInfo] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        return content.displays.map {
            DisplayInfo(id: $0.displayID, width: $0.width, height: $0.height, name: "Display \($0.displayID)")
        }
    }

    // MARK: - フレームの受け口

    /// フレームの転送先を設定する。ハンドラはキャプチャ用キューから呼ばれる。
    func setFrameHandler(_ handler: (@Sendable (CMSampleBuffer) -> Void)?) {
        stateLock.withLock { frameHandler = handler }
    }

    /// ストリームが自発的に停止したときの通知先。ディスプレイの切断や権限剥奪で呼ばれる。
    /// これを拾わないと、実際には止まっているのに UI が「実行中」のまま残る。
    func setStopHandler(_ handler: (@Sendable (Error) -> Void)?) {
        stateLock.withLock { stopHandler = handler }
    }

    func currentStatistics() -> Statistics {
        stateLock.withLock { statistics }
    }

    // MARK: - ライフサイクル

    func start(_ configuration: Configuration) async throws {
        await stop()

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == configuration.displayID }) else {
            throw CaptureError.displayNotFound(configuration.displayID)
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let stream = SCStream(filter: filter, configuration: Self.streamConfiguration(configuration), delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
        try await stream.startCapture()

        stateLock.withLock {
            self.stream = stream
            statistics = Statistics()
        }

        log.info("capture started: display=\(configuration.displayID) \(configuration.width)x\(configuration.height)")
    }

    /// 解像度だけを差し替える（SPEC.md §7.1 の解像度追従）。
    ///
    /// ストリームを張り直すと、切り替えのたびに数フレーム落ちてキーフレームからやり直しになる。
    /// `SCStream.updateConfiguration` は動いているストリームのまま構成を差し替える。
    /// 動いていなければ何もしない（承認前など、まだ開始していない場合）。
    func update(_ configuration: Configuration) async throws {
        guard let stream = stateLock.withLock({ self.stream }) else { return }
        try await stream.updateConfiguration(Self.streamConfiguration(configuration))
        log.info("capture reconfigured: \(configuration.width)x\(configuration.height)")
    }

    private static func streamConfiguration(_ configuration: Configuration) -> SCStreamConfiguration {
        let streamConfiguration = SCStreamConfiguration()
        streamConfiguration.width = configuration.width
        streamConfiguration.height = configuration.height
        // 上限であって下限ではない。変化がなければフレームは届かない
        streamConfiguration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(configuration.maximumFrameRate))
        // 大きすぎるとフレームが溜まって遅延になる（docs/STACK.md §2.2）
        streamConfiguration.queueDepth = 5
        streamConfiguration.showsCursor = configuration.showsCursor
        // VideoToolbox がそのまま扱えるフォーマット
        streamConfiguration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        return streamConfiguration
    }

    func stop() async {
        let running = stateLock.withLock {
            let current = stream
            stream = nil
            return current
        }

        guard let running else { return }
        try? await running.stopCapture()
        log.info("capture stopped")
    }
}

// MARK: - SCStreamDelegate

extension ScreenCapturer: SCStreamDelegate {
    /// ディスプレイの切断、画面構成の変更、権限の剥奪などでストリームが落ちたときに呼ばれる。
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // `stop()` は保持を外してから停止するため、自発的な停止だけがここに残る
        let handler = stateLock.withLock { () -> (@Sendable (Error) -> Void)? in
            guard self.stream === stream else { return nil }
            self.stream = nil
            return stopHandler
        }

        guard let handler else { return }
        log.error("capture stopped unexpectedly: \(error.localizedDescription)")
        handler(error)
    }
}

// MARK: - SCStreamOutput

extension ScreenCapturer: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }

        guard frameStatus(of: sampleBuffer) == .complete,
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else {
            // `.idle` は画面に変化がないことを意味する。送出しない（SPEC.md §4.3）
            stateLock.withLock { statistics.droppedFrames += 1 }
            return
        }

        let handler = stateLock.withLock {
            statistics.deliveredFrames += 1
            statistics.lastFrameSize = CGSize(
                width: CVPixelBufferGetWidth(imageBuffer),
                height: CVPixelBufferGetHeight(imageBuffer)
            )
            return frameHandler
        }

        handler?(sampleBuffer)
    }

    private func frameStatus(of sampleBuffer: CMSampleBuffer) -> SCFrameStatus? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
            let raw = attachments.first?[.status] as? Int
        else { return nil }
        return SCFrameStatus(rawValue: raw)
    }
}
