import Foundation

/// `--selftest --serve`。UI を出さずに実際の配信経路（キャプチャ → LocalServer → PeerTransport）を
/// 立ち上げ、ビューアが繋がって映像が流れたかを機械的に確認する。
///
/// `SessionController` をそのまま駆動するため、**製品と同じ経路を検証する**。
/// 接続先は待受開始と同時に `serve.json` へ書き出すので、E2E 側はそれを読んでブラウザを開く。
extension SelfTest {

    struct ServeReport: Codable {
        var port: Int
        var token: String
        var urls: [String]
        var viewerConnected: Bool
        var viewerState: String
        var iceConnectionState: String
        var codec: String?
        var framesSent: Int
        var frameWidth: Int
        var frameHeight: Int
        var candidatePairs: [String]
    }

    /// 待受開始を E2E 側へ知らせるための受け渡し。ビューアの URL はここから組み立てる
    struct ServeHandshake: Codable {
        var port: Int
        var token: String
        var urls: [String]
    }

    @MainActor
    static func performServe(_ options: Options) async -> Report {
        var report = Report(permissionGranted: ScreenRecordingPermission.isGranted)

        guard report.permissionGranted else {
            report.error = "画面収録が許可されていません。`make macos-run` で起動して許可してください"
            return report
        }

        let session = SessionController()
        session.refreshDisplays()

        guard await waitUntil(timeout: .seconds(5), { !session.displays.isEmpty }) else {
            report.error = "ディスプレイが 1 台も見つかりません"
            return report
        }
        report.displays = session.displays.map(Report.Display.init)

        if let requested = options.displayID {
            guard session.displays.contains(where: { $0.id == requested }) else {
                report.error = "ディスプレイ \(requested) が見つかりません"
                return report
            }
            session.selectDisplay(requested)
        }

        // `startCapture()` は直列キューへ積むだけで即座には状態が変わらない。
        // 「`.starting` でない」で待つと積む前の `.idle` を拾って素通りする
        session.startCapture()
        let settled = await waitUntil(timeout: .seconds(10)) {
            switch session.captureState {
            case .running, .failed: true
            case .idle, .starting: false
            }
        }
        guard settled else {
            report.error = "キャプチャが開始しませんでした"
            return report
        }
        if case .failed(let message) = session.captureState {
            report.error = message
            return report
        }

        guard let port = session.serverPort else {
            report.error = "待受ポートを確保できませんでした"
            return report
        }

        let handshake = ServeHandshake(
            port: port,
            token: session.token,
            urls: session.endpoints.map(\.url)
        )
        write(handshake, named: "serve.json", to: options.outputDirectory)

        // ビューアの接続を待つ。来なければ来なかったことを記録して終わる
        let connected = await waitUntil(timeout: options.duration) {
            if case .streaming = session.viewerState { return true }
            return false
        }
        // 繋がった直後は統計が空なので、少し流してから読む
        if connected { try? await Task.sleep(for: .seconds(3)) }

        let statistics = await session.streamStatistics()
        report.serve = ServeReport(
            port: port,
            token: session.token,
            urls: handshake.urls,
            viewerConnected: connected,
            viewerState: describe(session.viewerState),
            iceConnectionState: statistics?.iceConnectionState ?? "none",
            codec: statistics?.codec,
            framesSent: statistics?.framesSent ?? 0,
            frameWidth: statistics?.frameWidth ?? 0,
            frameHeight: statistics?.frameHeight ?? 0,
            candidatePairs: statistics?.candidatePairs ?? []
        )

        session.stopCapture()

        if !connected {
            report.error = "ビューアが接続しませんでした（\(handshake.urls.joined(separator: " / "))）"
        } else if (statistics?.framesSent ?? 0) == 0 {
            report.error = "ビューアへフレームが 1 枚も送られていません"
        }
        report.ok = report.error == nil
        return report
    }

    private static func describe(_ state: SessionController.ViewerState) -> String {
        switch state {
        case .none: "none"
        case .negotiating(let address): "negotiating(\(address))"
        case .streaming(let address): "streaming(\(address))"
        case .failed(let reason): "failed(\(reason))"
        }
    }

    /// 条件が満たされるまで待つ。`SessionController` は `@Observable` だが、
    /// 検証用に変更通知を張るより、粗いポーリングの方が読みやすく壊れにくい。
    @MainActor
    private static func waitUntil(timeout: Duration, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    private static func write(_ value: some Encodable, named name: String, to directory: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appending(path: name), options: .atomic)
    }
}
