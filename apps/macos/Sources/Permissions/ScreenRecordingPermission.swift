import AppKit
import CoreGraphics

/// 画面収録権限（TCC）の確認と要求。
///
/// `CGRequestScreenCaptureAccess()` がプロンプトを出せるのはアプリごとに一度きりで、
/// 一度拒否されたあとは常に false を返す。そのためシステム設定への導線が必ず要る。
enum ScreenRecordingPermission {
    static var isGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// 未許諾ならプロンプトを出す。既に拒否済みの場合はプロンプトが出ず false が返る。
    @discardableResult
    static func request() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    @MainActor
    static func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
