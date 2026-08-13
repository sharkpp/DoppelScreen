import SwiftUI

/// メインウィンドウの識別子。`MenuBarExtra` から開き直すために UI 側が持つ
enum MainWindow {
    static let id = "main"
}

/// メニューバーの中身。**ふつうのメニュー**として組む（`.menuBarExtraStyle` は既定の `.menu`）。
///
/// ここに置くのは「状態を読む」「ウィンドウを開く」「待受を切り替える」「終える」まで。
/// **承認はウィンドウでしか行わない**（SPEC.md §5.2）— 誰を通すかの判断は、
/// 相手のアドレスと対象の画面が並んで見える場所でだけ押せるようにする。
struct MenuBarView: View {
    let session: SessionController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(statusText)

        ForEach(session.streams.filter(\.isActive), id: \.id) { stream in
            Text(stream.display.name)
        }

        Divider()

        switch session.serverState {
        case .idle, .failed:
            Button(L10n.Control.start) { session.startServing() }
                .disabled(session.displays.isEmpty)
        case .starting:
            Text(L10n.Menu.starting)
        case .running:
            Button(L10n.Control.stop) { session.stopServing() }
        }

        Button(L10n.Menu.showWindow) { open(MainWindow.id) }

        Divider()

        Button(L10n.Menu.about) { open(AboutWindow.id) }
        Button(L10n.Menu.quit) { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// Dock アイコンを持たないため、ウィンドウを出すだけでは前面に来ない。
    /// 明示的にアクティブにする
    private func open(_ id: String) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }

    private var statusText: String {
        let requests = session.approvalRequests.count
        if requests > 0 { return L10n.Menu.requests(count: String(requests)) }

        return switch session.serverState {
        case .idle: L10n.Menu.stopped
        case .starting: L10n.Menu.starting
        case .running: L10n.Menu.serving(count: String(session.streams.filter(\.isActive).count))
        case .failed: L10n.Menu.failed
        }
    }
}
