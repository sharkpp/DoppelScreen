import Foundation
import OSLog
import WebRTC

private let log = Logger(subsystem: "net.sharkpp.doppelscreen", category: "loopback")

/// 同一プロセス内に `RTCPeerConnection` を 2 つ作り、offer / answer を直結して
/// キャプチャ → エンコード → 転送 → デコードが通ることを確認する（docs/STACK.md §2.8 ステップ 4）。
///
/// シグナリングもブラウザも介さないため、libwebrtc 自体の問題と、その外側の問題を切り分けられる。
final class WebRTCLoopback: @unchecked Sendable {

    struct Result: Sendable {
        var iceConnectionState: String = "new"
        var codec: String?
        var framesEncoded: Int = 0
        var framesDecoded: Int = 0
        var decodedWidth: Int = 0
        var decodedHeight: Int = 0
        /// レンダラに届いたフレーム数。デコード後の実データが来ている証拠
        var renderedFrames: Int = 0
        /// ICE の接続性チェックの内訳。「送れていない」のか「返ってこない」のかを切り分ける
        var candidatePairs: [String] = []
    }

    enum LoopbackError: LocalizedError {
        case connectionTimedOut

        var errorDescription: String? {
            switch self {
            case .connectionTimedOut: "ループバックの接続が確立しませんでした"
            }
        }
    }

    let pipeline: VideoPipeline

    private let factory: RTCPeerConnectionFactory
    private let sender: RTCPeerConnection
    private let receiver: RTCPeerConnection
    private let senderObserver = PeerObserver()
    private let receiverObserver = PeerObserver()
    private let collector = FrameCollector()
    /// 受信トラックのラッパー。保持しないとレンダラが外れる（`attachRenderer`）
    private var remoteTrack: RTCVideoTrack?

    /// リモート記述が入る前に届いた candidate は捨てられるため、溜めてから流す
    private let toReceiver = CandidateRelay()
    private let toSender = CandidateRelay()

    private let lock = NSLock()
    private var connectionContinuation: CheckedContinuation<Bool, Never>?
    private var connectionOutcome: Bool?

    init() {
        factory = VideoPipeline.makeFactory()
        pipeline = VideoPipeline(factory: factory)

        let configuration = RTCConfiguration()
        // LAN 内直結なので host candidate だけで成立する（SPEC.md §2.1）
        configuration.iceServers = []
        configuration.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)

        guard let sender = factory.peerConnection(with: configuration, constraints: constraints, delegate: senderObserver),
              let receiver = factory.peerConnection(with: configuration, constraints: constraints, delegate: receiverObserver)
        else {
            fatalError("RTCPeerConnection を生成できません")
        }
        self.sender = sender
        self.receiver = receiver
        senderObserver.name = "sender"
        receiverObserver.name = "receiver"

        senderObserver.onCandidate = { [toReceiver] candidate in
            toReceiver.send(candidate)
        }
        receiverObserver.onCandidate = { [toSender] candidate in
            toSender.send(candidate)
        }
        receiverObserver.onIceConnectionState = { [weak self] state in
            switch state {
            case .connected, .completed: self?.settle(true)
            case .failed, .closed: self?.settle(false)
            default: break
            }
        }
    }

    // MARK: - 接続

    func connect() async throws {
        sender.add(pipeline.track, streamIds: ["screen"])

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let offer = try await sender.offer(for: constraints)
        try await sender.setLocalDescription(offer)
        try await receiver.setRemoteDescription(offer)
        toReceiver.attach(receiver)

        let answer = try await receiver.answer(for: constraints)
        try await receiver.setLocalDescription(answer)
        try await sender.setRemoteDescription(answer)
        toSender.attach(sender)

        attachRenderer()
    }

    /// 受信トラックにレンダラを繋ぐ。`didAdd rtpReceiver:` は任意実装のデリゲートで、
    /// 呼ばれるかどうかが libwebrtc の版に依存するため、ここで明示的に取りに行く。
    ///
    /// `rtpReceiver.track` は呼ぶたびに新しいラッパーを返す。保持しないと解放時に
    /// レンダラごと外され、デコードは進むのにフレームが 1 枚も届かない状態になる。
    private func attachRenderer() {
        for rtpReceiver in receiver.receivers {
            guard let track = rtpReceiver.track as? RTCVideoTrack else { continue }
            remoteTrack = track
            track.add(collector)
            log.info("renderer attached: \(track.trackId, privacy: .public)")
        }
    }

    /// 接続を待つ。`withCheckedContinuation` はキャンセルできないため、
    /// タイムアウトも「同じ継続を一度だけ解放する」形で表現する。
    func waitUntilConnected(timeout: Duration) async throws {
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.settle(false)
        }
        defer { timeoutTask.cancel() }

        guard await waitForConnection() else { throw LoopbackError.connectionTimedOut }
    }

    private func waitForConnection() async -> Bool {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let outcome = connectionOutcome {
                lock.unlock()
                continuation.resume(returning: outcome)
                return
            }
            connectionContinuation = continuation
            lock.unlock()
        }
    }

    private func settle(_ connected: Bool) {
        let continuation = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
            guard connectionOutcome == nil else { return nil }
            connectionOutcome = connected
            let pending = connectionContinuation
            connectionContinuation = nil
            return pending
        }
        continuation?.resume(returning: connected)
    }

    // MARK: - 結果

    /// デコード済みの最新フレーム。ピクセル経路が正しいことの確認に使う
    var latestDecodedFrame: RTCVideoFrame? { collector.latest }

    func result() async -> Result {
        var result = Result()
        result.iceConnectionState = receiver.iceConnectionState.label
        result.renderedFrames = collector.count

        for statistics in await sender.statistics().statistics.values {
            switch statistics.type {
            case "outbound-rtp":
                result.framesEncoded = statistics.values["framesEncoded"] as? Int ?? 0
            case "candidate-pair":
                let state = statistics.values["state"] as? String ?? "?"
                let sent = statistics.values["requestsSent"] as? Int ?? 0
                let received = statistics.values["responsesReceived"] as? Int ?? 0
                result.candidatePairs.append("\(state) sent=\(sent) received=\(received)")
            default:
                break
            }
        }

        for statistics in await receiver.statistics().statistics.values {
            switch statistics.type {
            case "inbound-rtp":
                result.framesDecoded = statistics.values["framesDecoded"] as? Int ?? 0
                result.decodedWidth = statistics.values["frameWidth"] as? Int ?? 0
                result.decodedHeight = statistics.values["frameHeight"] as? Int ?? 0
            case "codec":
                result.codec = statistics.values["mimeType"] as? String
            default:
                break
            }
        }

        return result
    }

    func close() {
        sender.close()
        receiver.close()
    }
}

// MARK: - デコード済みフレームの受け口

/// `RTCVideoRenderer` として最新フレームと到達数だけを拾う。
private final class FrameCollector: NSObject, RTCVideoRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private var frame: RTCVideoFrame?
    private var received = 0

    var latest: RTCVideoFrame? { lock.withLock { frame } }
    var count: Int { lock.withLock { received } }

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        lock.withLock {
            self.frame = frame
            received += 1
        }
    }
}
