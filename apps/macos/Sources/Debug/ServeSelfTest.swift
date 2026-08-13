import CoreGraphics
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
        /// 配信した画面。URL は画面ごとに分かれる（SPEC.md §5.2）
        var displayID: CGDirectDisplayID
        var urls: [String]
        var secureUrls: [String]
        /// 証明書を用意できなかった理由。HTTP だけで動いている状態
        var certificateError: String?
        var viewerConnected: Bool
        var viewerState: String
        var iceConnectionState: String
        var codec: String?
        /// `VideoToolbox` 以外ならハードウェアエンコードが効いていない
        var encoderImplementation: String?
        var framesSent: Int
        var frameWidth: Int
        var frameHeight: Int
        /// キャプチャ時に要求した解像度。送出解像度が落ちていないかの突き合わせに使う
        var capturedWidth: Int
        var capturedHeight: Int
        var framesEncoded: Int
        var keyFramesEncoded: Int
        var encodeMs: Double
        var packetSendMs: Double
        var targetBitrateMbps: Double
        var qualityLimitationReason: String
        /// ビューアが選んだ品質プリセット（SPEC.md §7.2）
        var quality: String
        var candidatePairs: [String]
    }

    /// 待受開始を E2E 側へ知らせるための受け渡し。ビューアの URL はここから組み立てる
    struct ServeHandshake: Codable {
        var port: Int
        var securePort: Int?
        var token: String
        /// 配信対象の画面。ビューアは `?d=` でこれを指す
        var displayID: CGDirectDisplayID
        /// 画面の実解像度。解像度追従（SPEC.md §7.1）が効いたかの突き合わせに使う
        var displayWidth: Int
        var displayHeight: Int
        /// 待ち受けている全画面。同時配信の確認に使う
        var displayIDs: [CGDirectDisplayID]
        var urls: [String]
        var secureUrls: [String]
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

        let target: DisplayInfo?
        if let requested = options.displayID {
            target = session.displays.first { $0.id == requested }
        } else {
            target = session.displays.first
        }
        guard let target, let stream = session.streams.first(where: { $0.id == target.id }) else {
            report.error = options.displayID.map { "ディスプレイ \($0) が見つかりません" }
                ?? "ディスプレイが 1 台も見つかりません"
            return report
        }

        // `startServing()` は直列キューへ積むだけで即座には状態が変わらない。
        // 「`.starting` でない」で待つと積む前の `.idle` を拾って素通りする
        session.startServing()
        let settled = await waitUntil(timeout: .seconds(10)) {
            switch session.serverState {
            case .running, .failed: true
            case .idle, .starting: false
            }
        }
        guard settled else {
            report.error = "待受が始まりませんでした"
            return report
        }
        if case .failed(let message) = session.serverState {
            report.error = message
            return report
        }

        guard let port = session.serverPort else {
            report.error = "待受ポートを確保できませんでした"
            return report
        }

        let handshake = ServeHandshake(
            port: port,
            securePort: session.securePort,
            token: session.token,
            displayID: target.id,
            displayWidth: target.pixelWidth,
            displayHeight: target.pixelHeight,
            displayIDs: session.displays.map(\.id),
            urls: session.endpoints(for: target.id).map(\.url),
            secureUrls: session.endpoints(for: target.id).compactMap(\.secureURL)
        )
        write(handshake, named: "serve.json", to: options.outputDirectory)

        // 承認は本来ホスト UI で人が押す（SPEC.md §5.2）。検証モードでは
        // **同じ API を機械が押す**。承認経路そのものを迂回すると、製品と違う経路を測ることになる
        let approver = Task { @MainActor in
            while !Task.isCancelled {
                for stream in session.streams {
                    if case .awaitingApproval = stream.state { stream.approve() }
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        defer { approver.cancel() }

        // ビューアの接続を待つ。来なければ来なかったことを記録して終わる
        let deadline = ContinuousClock.now + options.duration
        let connected = await waitUntil(timeout: options.duration) {
            if case .streaming = stream.state { return true }
            return false
        }
        // 繋がったら `--duration` を使い切るまで配信を続ける。統計は落ち着いてから読みたいのと、
        // 手で繋いだときに数秒で切れないようにするため。最低 3 秒は流す
        if connected {
            let until = max(deadline, ContinuousClock.now + .seconds(3))
            try? await Task.sleep(until: until, clock: .continuous)
        }

        let statistics = stream.streamStatistics
        let captured = stream.activeConfiguration
        report.serve = ServeReport(
            port: port,
            token: session.token,
            displayID: target.id,
            urls: handshake.urls,
            secureUrls: handshake.secureUrls,
            certificateError: session.certificateError,
            viewerConnected: connected,
            viewerState: describe(stream.state),
            iceConnectionState: statistics?.iceConnectionState ?? "none",
            codec: statistics?.codec,
            encoderImplementation: statistics?.encoderImplementation,
            framesSent: statistics?.framesSent ?? 0,
            frameWidth: statistics?.frameWidth ?? 0,
            frameHeight: statistics?.frameHeight ?? 0,
            capturedWidth: captured?.width ?? 0,
            capturedHeight: captured?.height ?? 0,
            framesEncoded: statistics?.framesEncoded ?? 0,
            keyFramesEncoded: statistics?.keyFramesEncoded ?? 0,
            encodeMs: statistics?.encodeMs ?? 0,
            packetSendMs: statistics?.packetSendMs ?? 0,
            targetBitrateMbps: statistics?.targetBitrateMbps ?? 0,
            qualityLimitationReason: statistics?.qualityLimitationReason ?? "none",
            quality: stream.quality.rawValue,
            candidatePairs: statistics?.candidatePairs ?? []
        )

        session.stopServing()

        if !connected {
            report.error = "ビューアが接続しませんでした（\(handshake.urls.joined(separator: " / "))）"
        } else if (statistics?.framesSent ?? 0) == 0 {
            report.error = "ビューアへフレームが 1 枚も送られていません"
        }
        report.ok = report.error == nil
        return report
    }

    private static func describe(_ state: DisplayStream.State) -> String {
        switch state {
        case .idle: "idle"
        case .awaitingApproval(let address): "awaitingApproval(\(address))"
        case .starting(let address): "starting(\(address))"
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
