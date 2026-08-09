import CoreImage
import CoreMedia
import Foundation
import ScreenCaptureKit

/// UI を出さずにキャプチャを一通り走らせ、結果を JSON と PNG で書き出す検証モード。
///
/// 人がプレビューを目視しなくても「権限が有効か」「ディスプレイ列挙が実態と合っているか」
/// 「フレームが届いているか」「静止時に `idle` として抑制されているか」を機械的に確認できる。
///
/// `LocalServer` の `/debug` に載せる案は採らない。LAN に開くサーバへデバッグ経路を
/// 常駐させたくないのと、起動〜キャプチャ〜終了を通しで見るほうが回帰検出に向くため。
enum SelfTest {

    // MARK: - 起動引数

    struct Options {
        static let flag = "--selftest"

        var displayID: CGDirectDisplayID?
        var duration: Duration = .seconds(3)
        var outputDirectory: URL = FileManager.default.temporaryDirectory
            .appending(path: "doppelscreen-selftest", directoryHint: .isDirectory)

        static func isRequested(_ arguments: [String]) -> Bool {
            arguments.contains(flag)
        }

        /// `--selftest [--display <id>] [--duration <秒>] [--output <ディレクトリ>]`
        init(arguments: [String]) throws {
            var iterator = arguments.dropFirst().makeIterator()
            while let argument = iterator.next() {
                switch argument {
                case Options.flag:
                    continue
                case "--display":
                    guard let value = iterator.next(), let id = UInt32(value) else {
                        throw Failure("--display にはディスプレイ ID を指定してください")
                    }
                    displayID = id
                case "--duration":
                    guard let value = iterator.next(), let seconds = Double(value), seconds > 0 else {
                        throw Failure("--duration には正の秒数を指定してください")
                    }
                    duration = .seconds(seconds)
                case "--output":
                    guard let value = iterator.next() else {
                        throw Failure("--output にはディレクトリを指定してください")
                    }
                    outputDirectory = URL(filePath: value, directoryHint: .isDirectory)
                default:
                    throw Failure("不明な引数: \(argument)")
                }
            }
        }
    }

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    // MARK: - 出力

    struct Report: Codable {
        struct Display: Codable {
            var id: CGDirectDisplayID
            var name: String
            var width: Int
            var height: Int
            var scale: Double
            var pixelWidth: Int
            var pixelHeight: Int

            init(_ display: DisplayInfo) {
                id = display.id
                name = display.name
                width = display.width
                height = display.height
                scale = display.scaleFactor
                pixelWidth = display.pixelWidth
                pixelHeight = display.pixelHeight
            }
        }

        struct Capture: Codable {
            var displayID: CGDirectDisplayID
            var requestedWidth: Int
            var requestedHeight: Int
            var durationSeconds: Double
            /// `.complete` で届いたフレーム数
            var deliveredFrames: Int
            /// `.idle` 等で破棄したフレーム数。静止時の抑制が効いている指標
            var idleFrames: Int
            var lastFrameWidth: Int
            var lastFrameHeight: Int
            /// 最終フレームを書き出した PNG のパス
            var framePath: String
        }

        var ok: Bool = false
        var permissionGranted: Bool
        var displays: [Display] = []
        var capture: Capture?
        var error: String?
    }

    // MARK: - 実行

    /// 検証を実行し、プロセスを終了する。
    @MainActor
    static func run(arguments: [String]) -> Never {
        let options: Options
        do {
            options = try Options(arguments: arguments)
        } catch {
            emit(Report(permissionGranted: false, error: error.localizedDescription), to: nil)
            exit(2)
        }

        // ストリームが開かないまま待ち続けると `open -W` が返らなくなる
        let watchdog = Task {
            try? await Task.sleep(for: options.duration + .seconds(15))
            emit(
                Report(permissionGranted: ScreenRecordingPermission.isGranted, error: "タイムアウトしました"),
                to: options.outputDirectory
            )
            exit(1)
        }

        Task {
            let report = await perform(options)
            watchdog.cancel()
            emit(report, to: options.outputDirectory)
            exit(report.ok ? 0 : 1)
        }

        // ScreenCaptureKit の非同期処理を回すためにメインループを走らせる
        RunLoop.main.run()
        fatalError("unreachable")
    }

    @MainActor
    private static func perform(_ options: Options) async -> Report {
        var report = Report(permissionGranted: ScreenRecordingPermission.isGranted)

        guard report.permissionGranted else {
            report.error = """
                画面収録が許可されていません。`make macos-run` で起動して許可してください。\
                署名 ID を切り替えた直後は TCC から見て別アプリになるため、\
                先に `make macos-reset-permission` が要ります
                """
            return report
        }

        let capturer = ScreenCapturer()
        let latestFrame = FrameBox()
        capturer.setFrameHandler { latestFrame.store($0) }

        let displays: [DisplayInfo]
        do {
            displays = try await capturer.availableDisplays().map(DisplayNaming.decorate)
        } catch {
            report.error = "ディスプレイの列挙に失敗しました: \(error.localizedDescription)"
            return report
        }
        report.displays = displays.map(Report.Display.init)

        let target: DisplayInfo?
        if let requested = options.displayID {
            target = displays.first { $0.id == requested }
        } else {
            target = displays.first
        }
        guard let target else {
            report.error = options.displayID.map { "ディスプレイ \($0) が見つかりません" }
                ?? "ディスプレイが 1 台も見つかりません"
            return report
        }

        let configuration = ScreenCapturer.Configuration(
            displayID: target.id,
            width: target.pixelWidth,
            height: target.pixelHeight
        )

        do {
            try await capturer.start(configuration)
        } catch {
            report.error = "キャプチャの開始に失敗しました: \(error.localizedDescription)"
            return report
        }

        try? await Task.sleep(for: options.duration)

        let statistics = capturer.currentStatistics()

        // ストリームを止める前に書き出す。停止後はピクセルバッファが回収されうる
        let framePath = options.outputDirectory.appending(path: "frame.png")
        var writeError: String?
        if let sampleBuffer = latestFrame.take() {
            do {
                try writePNG(sampleBuffer, to: framePath, in: options.outputDirectory)
            } catch {
                writeError = "フレームの書き出しに失敗しました: \(error.localizedDescription)"
            }
        } else {
            writeError = "フレームが 1 枚も届きませんでした"
        }

        await capturer.stop()

        report.capture = Report.Capture(
            displayID: configuration.displayID,
            requestedWidth: configuration.width,
            requestedHeight: configuration.height,
            durationSeconds: options.duration.seconds,
            deliveredFrames: statistics.deliveredFrames,
            idleFrames: statistics.droppedFrames,
            lastFrameWidth: Int(statistics.lastFrameSize.width),
            lastFrameHeight: Int(statistics.lastFrameSize.height),
            framePath: framePath.path(percentEncoded: false)
        )
        report.error = writeError
        report.ok = writeError == nil && statistics.deliveredFrames > 0
        return report
    }

    // MARK: - 書き出し

    private static func writePNG(_ sampleBuffer: CMSampleBuffer, to url: URL, in directory: URL) throws {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            throw Failure("フレームからピクセルバッファを取り出せません")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try CIContext().writePNGRepresentation(
            of: CIImage(cvPixelBuffer: pixelBuffer),
            to: url,
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
    }

    /// `open -W` 経由では stdout が拾えないため、ファイルにも残す。
    private static func emit(_ report: Report, to directory: URL?) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(report) else { return }

        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))

        guard let directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // 書き込み途中のファイルを読まれないように差し替えで置く（待ち受け側がポーリングする）
        try? data.write(to: directory.appending(path: "report.json"), options: .atomic)
    }

    /// 最新フレームだけを保持する。キャプチャ用キューとメインアクタの両方から触る。
    private final class FrameBox: @unchecked Sendable {
        private let lock = NSLock()
        private var sampleBuffer: CMSampleBuffer?

        func store(_ sampleBuffer: CMSampleBuffer) {
            lock.withLock { self.sampleBuffer = sampleBuffer }
        }

        func take() -> CMSampleBuffer? {
            lock.withLock { sampleBuffer }
        }
    }
}

private extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
