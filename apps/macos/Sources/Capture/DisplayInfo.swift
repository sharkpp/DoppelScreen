import AppKit
import CoreGraphics

/// キャプチャ対象のディスプレイ。UI 層は `SCDisplay` を直接扱わない。
struct DisplayInfo: Identifiable, Hashable, Sendable {
    let id: CGDirectDisplayID
    /// ポイント単位のサイズ（`SCDisplay` が返す値）
    let width: Int
    let height: Int
    /// 表示名。ScreenCaptureKit は名前を持たないため `NSScreen` から補う
    var name: String

    /// 物理ピクセル単位のサイズ
    var pixelWidth: Int { Int(Double(width) * scaleFactor) }
    var pixelHeight: Int { Int(Double(height) * scaleFactor) }

    var scaleFactor: Double = 1.0
}

/// `NSScreen` は `@MainActor` 隔離のため、名前とスケールの解決はメインアクタで行う。
@MainActor
enum DisplayNaming {
    static func decorate(_ display: DisplayInfo) -> DisplayInfo {
        guard let screen = screen(for: display.id) else { return display }
        var decorated = display
        decorated.name = screen.localizedName
        decorated.scaleFactor = screen.backingScaleFactor
        return decorated
    }

    private static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            guard let number = screen.deviceDescription[key] as? NSNumber else { return false }
            return CGDirectDisplayID(number.uint32Value) == displayID
        }
    }
}
