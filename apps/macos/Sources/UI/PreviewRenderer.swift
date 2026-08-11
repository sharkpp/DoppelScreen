import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation

/// キャプチャしたフレームをプレビュー用のレイヤへ流す。
///
/// キャプチャ用キューから直接呼ばれるため、レイヤ参照をロックで守って保持する。
/// フレームを `MainActor` へ運ばないことが目的（運ぶとコピーと遅延が発生する）。
/// 画面ごとに独立したストリームが同時に走るため（SPEC.md §5.2）、どの画面を映すかを
/// `source` で選ぶ。他の画面のフレームはここで捨てる。
final class PreviewRenderer: @unchecked Sendable {

    private let lock = NSLock()
    private var renderer: AVSampleBufferVideoRenderer?
    private var _source: CGDirectDisplayID?

    /// プレビューに映す画面。切り替えたら前の画面の残像を消す
    var source: CGDirectDisplayID? {
        get { lock.withLock { _source } }
        set {
            let target = lock.withLock { () -> AVSampleBufferVideoRenderer? in
                guard _source != newValue else { return nil }
                _source = newValue
                return renderer
            }
            target?.flush()
        }
    }

    func attach(_ renderer: AVSampleBufferVideoRenderer?) {
        lock.lock()
        defer { lock.unlock() }
        self.renderer = renderer
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer, from displayID: CGDirectDisplayID) {
        lock.lock()
        let target = _source == displayID ? renderer : nil
        lock.unlock()

        guard let target else { return }
        if target.status == .failed {
            target.flush()
        }
        Self.markDisplayImmediately(sampleBuffer)
        target.enqueue(sampleBuffer)
    }

    /// ライブ映像なので到着したフレームは即座に表示する。
    /// これを付けないとレンダラがタイムベースを待ち、何も表示されない。
    private static func markDisplayImmediately(_ sampleBuffer: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
              CFArrayGetCount(attachments) > 0
        else { return }

        let raw = CFArrayGetValueAtIndex(attachments, 0)
        let dictionary = unsafeBitCast(raw, to: CFMutableDictionary.self)
        CFDictionarySetValue(
            dictionary,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        )
    }
}
