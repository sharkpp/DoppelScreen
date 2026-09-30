import SwiftUI

/// 起動引数で通常のアプリと検証モードを振り分ける（`SelfTest`）。
@main
enum DoppelScreenMain {
    @MainActor
    static func main() {
        if SelfTest.Options.isRequested(CommandLine.arguments) {
            SelfTest.run(arguments: CommandLine.arguments)
        }
        DoppelScreenApp.main()
    }
}

/// メニューバー常駐（`LSUIElement`）。Dock アイコンは持たない。
///
/// 画面を配信している間ユーザが見ているのは配信中の画面そのもので、この Mac の
/// 作業を妨げないことが正しい振る舞いになる。ウィンドウはペアリングと承認のために
/// 開く道具として扱い、常設しない。
struct DoppelScreenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var session: SessionController
    /// ウィンドウの中身を描く Flutter のエンジン。閉じても残す（docs/adr/0002-host-ui-flutter.md）
    @State private var hostUI: HostUIBridge

    init() {
        let session = SessionController()
        _session = State(initialValue: session)
        _hostUI = State(initialValue: HostUIBridge(session: session))
    }

    var body: some Scene {
        Window("DoppelScreen", id: MainWindow.id) {
            HostUIView(bridge: hostUI)
                .frame(minWidth: 520, minHeight: 360)
        }
        .defaultSize(width: 680, height: 520)

        Window(L10n.Menu.about, id: AboutWindow.id) {
            AboutView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        MenuBarExtra("DoppelScreen", systemImage: "rectangle.on.rectangle") {
            MenuBarView(session: session)
        }
    }
}

/// Dock アイコンを持たないアプリは、起動しても OS がウィンドウを前に出さない。
/// **起動したのに何も出ないと、初回の権限オンボーディングに辿り着けない。**
/// ウィンドウ自体は SwiftUI が作っているので、ここでは前に出すだけでよい。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        showMainWindow()
    }

    /// 起動中にもう一度アプリを開こうとしたとき（Finder から叩き直したなど）
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { showMainWindow() }
        return true
    }

    @MainActor
    private func showMainWindow() {
        // SwiftUI は `Window(id:)` の識別子をそのまま NSWindow に付ける。
        // 「について」を開いた状態で起動したときに、そちらを前に出さないため名前で選ぶ
        guard let window = NSApp.windows.first(where: {
            $0.identifier?.rawValue == MainWindow.id
        }) else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
