import CoreMedia
import Foundation
import WebRTC

/// キャプチャしたフレームを WebRTC のビデオトラックへ流す（SPEC.md §2.3）。
///
/// `CVPixelBuffer` は `RTCCVPixelBuffer` でラップするだけで、CPU 側のコピーを発生させない
/// （docs/STACK.md §2.2）。フレームはキャプチャ用キューから直接渡してよい。
final class VideoPipeline: @unchecked Sendable {

    let factory: RTCPeerConnectionFactory
    let track: RTCVideoTrack

    private let source: RTCVideoSource
    /// `RTCVideoSource` の API が要求するだけで、実際の取得は `ScreenCapturer` が行う
    private let capturer: RTCVideoCapturer

    init(factory: RTCPeerConnectionFactory, trackID: String = "screen") {
        self.factory = factory
        source = factory.videoSource()
        capturer = RTCVideoCapturer(delegate: source)
        track = factory.videoTrack(with: source, trackId: trackID)
    }

    /// libwebrtc の既定のエンコーダ／デコーダを使う。macOS では VideoToolbox が選ばれる。
    static func makeFactory() -> RTCPeerConnectionFactory {
        RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory()
        )
    }

    func capture(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let frame = RTCVideoFrame(
            buffer: RTCCVPixelBuffer(pixelBuffer: pixelBuffer),
            rotation: ._0,
            timeStampNs: Int64(timestamp.seconds * 1_000_000_000)
        )
        source.capturer(capturer, didCapture: frame)
    }
}
