import SwiftUI

/// メインウィンドウの識別子。`MenuBarExtra` から開き直すために UI 側が持つ
enum MainWindow {
    static let id = "main"
}

struct MenuBarView: View {
    let session: SessionController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(indicatorColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.callout.weight(.medium))
            }

            // 承認はウィンドウでしか行わない。ここでは件数だけ伝えて誘導する（SPEC.md §5.2）
            ForEach(session.streams.filter(\.isActive), id: \.id) { stream in
                Text(stream.display.name)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Button(L10n.Menu.showWindow) {
                openWindow(id: MainWindow.id)
                NSApp.activate(ignoringOtherApps: true)
            }

            Button(L10n.Menu.quit) {
                NSApp.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: 220)
    }

    private var indicatorColor: Color {
        if !session.approvalRequests.isEmpty { return .orange }
        return session.streams.contains(where: \.isActive) ? .green : .secondary
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
