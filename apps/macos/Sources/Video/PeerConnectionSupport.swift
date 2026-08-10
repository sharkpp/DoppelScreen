import Foundation
import OSLog
import WebRTC

private let log = Logger(subsystem: "net.sharkpp.doppelscreen", category: "webrtc")

/// リモート記述が入る前に届いた ICE candidate は捨てられる。宛先が決まるまで溜めておく。
///
/// ループバック検証（`WebRTCLoopback`）と実接続（`PeerTransport`）の両方で必要になる。
final class CandidateRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [RTCIceCandidate] = []
    private var target: RTCPeerConnection?

    func attach(_ peer: RTCPeerConnection) {
        let flushed = lock.withLock { () -> [RTCIceCandidate] in
            target = peer
            let queued = pending
            pending.removeAll()
            return queued
        }
        for candidate in flushed {
            peer.add(candidate) { _ in }
        }
    }

    func send(_ candidate: RTCIceCandidate) {
        let peer = lock.withLock { () -> RTCPeerConnection? in
            guard let target else {
                pending.append(candidate)
                return nil
            }
            return target
        }
        peer?.add(candidate) { _ in }
    }
}

/// `RTCPeerConnectionDelegate` は必須メソッドが多い。必要なものだけクロージャで外に出す。
final class PeerObserver: NSObject, RTCPeerConnectionDelegate, @unchecked Sendable {
    var name = "peer"
    var onCandidate: ((RTCIceCandidate) -> Void)?
    var onIceConnectionState: ((RTCIceConnectionState) -> Void)?

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        log.info("\(self.name, privacy: .public) candidate: \(candidate.sdp, privacy: .public)")
        onCandidate?(candidate)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        log.info("\(self.name, privacy: .public) ice: \(newState.rawValue, privacy: .public)")
        onIceConnectionState?(newState)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        log.info("\(self.name, privacy: .public) gathering: \(newState.rawValue, privacy: .public)")
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

extension RTCStatisticsReport {
    /// RTP ストリームが実際に使っているコーデック。
    ///
    /// `codec` の統計は**ネゴシエートされた全コーデックぶん**現れるため、種別だけで拾うと
    /// 使っていないものを掴む（実際に H.264 で流れているのに VP8 と報告された）。
    /// `inbound-rtp` / `outbound-rtp` が指す `codecId` から引く。
    func mimeType(of stream: RTCStatistics) -> String? {
        guard let id = stream.values["codecId"] as? String else { return nil }
        return statistics[id]?.values["mimeType"] as? String
    }
}

extension RTCIceConnectionState {
    var label: String {
        switch self {
        case .new: "new"
        case .checking: "checking"
        case .connected: "connected"
        case .completed: "completed"
        case .failed: "failed"
        case .disconnected: "disconnected"
        case .closed: "closed"
        case .count: "count"
        @unknown default: "unknown"
        }
    }
}
