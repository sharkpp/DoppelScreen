import AVFoundation
import SwiftUI

/// キャプチャ中の画面をそのまま表示する自己プレビュー。
/// `AVSampleBufferDisplayLayer` に `CMSampleBuffer` を直接渡すため、ピクセルのコピーが発生しない。
struct PreviewView: NSViewRepresentable {
    let renderer: PreviewRenderer

    func makeCoordinator() -> Coordinator {
        Coordinator(renderer: renderer)
    }

    func makeNSView(context: Context) -> SampleBufferHostView {
        let view = SampleBufferHostView()
        context.coordinator.attach(view.videoRenderer)
        return view
    }

    func updateNSView(_ nsView: SampleBufferHostView, context: Context) {}

    static func dismantleNSView(_ nsView: SampleBufferHostView, coordinator: Coordinator) {
        coordinator.detach()
    }

    /// ビューの寿命に合わせて `PreviewRenderer` の参照先を張り替える。
    @MainActor
    final class Coordinator {
        private let renderer: PreviewRenderer

        init(renderer: PreviewRenderer) {
            self.renderer = renderer
        }

        func attach(_ videoRenderer: AVSampleBufferVideoRenderer) {
            renderer.attach(videoRenderer)
        }

        func detach() {
            renderer.attach(nil)
        }
    }
}

/// `AVSampleBufferDisplayLayer` をホストする（レイヤバックではなくレイヤホスティング）。
final class SampleBufferHostView: NSView {
    private let displayLayer = AVSampleBufferDisplayLayer()

    var videoRenderer: AVSampleBufferVideoRenderer { displayLayer.sampleBufferRenderer }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        // レイヤホスティングでは layer を先に差し替えてから wantsLayer を立てる。
        // 順序を逆にするとレイヤバックのビューになり、差し替えたレイヤが描画されない。
        layer = displayLayer
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// レイヤホスティングのビューはレイヤの geometry を自動で追従しないため、明示的に合わせる。
    override func layout() {
        super.layout()
        displayLayer.frame = bounds
    }
}
