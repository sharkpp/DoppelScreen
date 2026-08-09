import AppKit
import CoreGraphics

/// 画面収録権限（TCC）の確認と要求。
///
/// 扱いづらい点が 3 つある。
///
/// 1. `CGRequestScreenCaptureAccess()` がプロンプトを出せるのはアプリごとに一度きり。
///    以降は何も起きず false を返すだけなので、押しても無反応に見える。
///    そのため「一度尋ねたか」を自前で覚え、二度目以降はシステム設定へ直接誘導する。
/// 2. システム設定で許可しても、実行中のプロセスには反映されない。**再起動が必要**。
/// 3. TCC は署名で同一性を判定する。ad-hoc 署名のアプリは cdhash がビルドごとに
///    変わるため、リビルドすると別アプリ扱いになり許可が失われる。
///    開発中に許可が外れて見えるのはこれが原因（`make macos-reset-permission` で解消）。
enum ScreenRecordingPermission {

    private static let hasRequestedKey = "net.sharkpp.doppelscreen.screenRecording.hasRequested"

    static var isGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// 一度でもプロンプトを出したか。出したあとは `request()` が無反応になる。
    static var hasRequestedBefore: Bool {
        UserDefaults.standard.bool(forKey: hasRequestedKey)
    }

    /// 未許諾ならプロンプトを出す。既に一度尋ねている場合はプロンプトが出ず false が返る。
    @discardableResult
    static func request() -> Bool {
        UserDefaults.standard.set(true, forKey: hasRequestedKey)
        return CGRequestScreenCaptureAccess()
    }

    @MainActor
    static func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// システム設定での許可をプロセスに反映させるには再起動が要る。
    @MainActor
    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            Task { @MainActor in
                NSApp.terminate(nil)
            }
        }
    }
}
