import Foundation
import OSLog
import WebRTC

private let log = Logger(subsystem: "net.sharkpp.doppelscreen", category: "transport")

/// ビューア 1 本ぶんの `RTCPeerConnection`（SPEC.md §2.3）。
///
/// ホストが offer を出し、ビューアが answer を返す（SPEC.md §5.1）。
/// シグナリングの往復は `SignalingConnection` に委ね、ここは WebRTC だけを見る。
final class PeerTransport: @unchecked Sendable {

    enum State: Sendable, Equatable {
        case negotiating
        case streaming
        case closed(String)
    }

    private let connection: SignalingConnection
    private let peer: RTCPeerConnection
    private let observer = PeerObserver()
    /// リモート記述が入る前に届いた candidate は捨てられる
    private let incoming = CandidateRelay()
    private let onStateChange: @Sendable (UUID, State) -> Void

    /// 接続元の表示用
    let remoteDescription: String
    /// 状態通知の宛先を見分けるための識別子。
    /// 古い接続の「切断しました」が、後から来た接続の状態を塗り潰さないようにする
    let id = UUID()

    init(
        factory: RTCPeerConnectionFactory,
        connection: SignalingConnection,
        onStateChange: @escaping @Sendable (UUID, State) -> Void
    ) throws {
        self.connection = connection
        self.onStateChange = onStateChange
        remoteDescription = connection.remoteDescription

        let configuration = RTCConfiguration()
        // LAN 内直結なので host candidate だけで成立する。STUN / TURN は持たない（SPEC.md §2.1）
        configuration.iceServers = []
        configuration.sdpSemantics = .unifiedPlan

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let peer = factory.peerConnection(with: configuration, constraints: constraints, delegate: observer) else {
            throw TransportError.peerConnectionUnavailable
        }
        self.peer = peer
        observer.name = "host"

        observer.onCandidate = { [connection] candidate in
            connection.send(.candidate(IceCandidate(
                candidate: candidate.sdp,
                sdpMid: candidate.sdpMid,
                sdpMLineIndex: candidate.sdpMLineIndex
            )))
        }
        observer.onIceConnectionState = { [weak self] state in
            switch state {
            case .connected, .completed: self?.report(.streaming)
            case .failed: self?.report(.closed("接続に失敗しました"))
            case .disconnected: self?.report(.closed("ビューアとの接続が切れました"))
            default: break
            }
        }
    }

    enum TransportError: LocalizedError {
        case peerConnectionUnavailable

        var errorDescription: String? {
            switch self {
            case .peerConnectionUnavailable: "PeerConnection を生成できません"
            }
        }
    }

    /// トラックを載せて offer を送る。以降はビューアからの answer / candidate を待つ。
    func start(track: RTCVideoTrack) async throws {
        connection.onSignal { [weak self] signal in
            Task { await self?.handle(signal) }
        }
        connection.onClose { [weak self] in
            self?.report(.closed("ビューアが切断しました"))
        }

        peer.add(track, streamIds: ["screen"])
        report(.negotiating)

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let offer = try await peer.offer(for: constraints)
        try await peer.setLocalDescription(offer)
        connection.send(.offer(sdp: offer.sdp))
        log.info("offer sent to \(self.remoteDescription, privacy: .public)")
    }

    func close() {
        peer.close()
        connection.close()
    }

    private func report(_ state: State) {
        onStateChange(id, state)
    }

    private func handle(_ signal: ViewerSignal) async {
        switch signal {
        case .answer(let sdp):
            do {
                try await peer.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp))
                incoming.attach(peer)
                log.info("answer accepted")
            } catch {
                log.error("failed to accept answer: \(error.localizedDescription, privacy: .public)")
                report(.closed("answer を受け付けられませんでした"))
            }
        case .candidate(let candidate):
            incoming.send(RTCIceCandidate(
                sdp: candidate.candidate,
                sdpMLineIndex: candidate.sdpMLineIndex ?? 0,
                sdpMid: candidate.sdpMid
            ))
        case .hello:
            // 認証は `LocalServer` が済ませている。ここへは来ない
            break
        }
    }

    /// 送出側の実測。遅延計測（SPEC.md §3.3）と検証モードの判定に使う
    struct Statistics: Sendable, Equatable {
        var iceConnectionState = "new"
        var codec: String?
        var framesSent = 0
        var frameWidth = 0
        var frameHeight = 0
        /// ICE の接続性チェックの内訳。「送れていない」のか「返ってこない」のかを切り分ける
        var candidatePairs: [String] = []
    }

    func statistics() async -> Statistics {
        var result = Statistics()
        result.iceConnectionState = peer.iceConnectionState.label

        for entry in await peer.statistics().statistics.values {
            switch entry.type {
            case "outbound-rtp":
                result.framesSent = entry.values["framesSent"] as? Int ?? 0
                result.frameWidth = entry.values["frameWidth"] as? Int ?? 0
                result.frameHeight = entry.values["frameHeight"] as? Int ?? 0
            case "codec":
                result.codec = entry.values["mimeType"] as? String
            case "candidate-pair":
                let state = entry.values["state"] as? String ?? "?"
                let sent = entry.values["requestsSent"] as? Int ?? 0
                let received = entry.values["responsesReceived"] as? Int ?? 0
                result.candidatePairs.append("\(state) sent=\(sent) received=\(received)")
            default:
                break
            }
        }
        return result
    }
}
