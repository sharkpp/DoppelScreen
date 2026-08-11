import SwiftUI

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

    private var indicatorColor: Color {
        if !session.approvalRequests.isEmpty { return .orange }
        return session.streams.contains(where: \.isActive) ? .green : .secondary
    }

    private var statusText: String {
        let requests = session.approvalRequests.count
        if requests > 0 { return "\(requests) 件の接続要求" }

        return switch session.serverState {
        case .idle: "停止中"
        case .starting: "開始中…"
        case .running: "待受中（\(session.streams.filter(\.isActive).count) 画面を配信）"
        case .failed: "エラー"
        }
    }
}
