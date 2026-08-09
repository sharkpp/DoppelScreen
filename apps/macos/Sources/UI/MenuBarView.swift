import SwiftUI

struct MenuBarView: View {
    let session: SessionController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(session.captureState == .running ? .green : .secondary)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.callout.weight(.medium))
            }

            if let display = session.selectedDisplay {
                Text(display.name)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Button("ウィンドウを表示") {
                openWindow(id: MainWindow.id)
                NSApp.activate(ignoringOtherApps: true)
            }

            Button("DoppelScreen を終了") {
                NSApp.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: 220)
    }

    private var statusText: String {
        switch session.captureState {
        case .idle: "停止中"
        case .starting: "開始中…"
        case .running: "配信中"
        case .failed: "エラー"
        }
    }
}
