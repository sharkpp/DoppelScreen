import SwiftUI

/// ホストの操作画面（SPEC.md §2.3 HostUI）。
///
/// **自分の画面の複製は映さない。** 見えているのは配信中の画面そのものであり、
/// 窓の中にもう一度出す意味がない。ここが受け持つのはペアリングと承認、そして
/// 「いま何が誰へ流れているか」だけ。
struct MainView: View {
    let session: SessionController

    var body: some View {
        Group {
            if session.permissionGranted {
                servingView
            } else {
                OnboardingView(session: session)
            }
        }
        // 権限はシステム設定側でいつでも変わりうる。未許可の間はポーリングして追従する
        .task(id: session.permissionGranted) {
            if session.permissionGranted {
                session.refreshDisplays()
                return
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                session.refreshPermission()
                if session.permissionGranted { break }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            session.refreshPermission()
        }
    }

    /// 待受の開始・停止はこの画面で最も大きい操作なので、ツールバーの主操作に置く。
    /// 状態は同じ並びの左側に出し、押した結果がその場で読めるようにする
    private var servingView: some View {
        Group {
            if session.isServing {
                ConnectionView(session: session)
            } else {
                idleView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            ToolbarItem(placement: .status) {
                statusLabel
            }
            ToolbarItem(placement: .primaryAction) {
                switch session.serverState {
                case .idle, .failed:
                    Button(L10n.Control.start) { session.startServing() }
                        .disabled(session.displays.isEmpty)
                case .starting:
                    ProgressView().controlSize(.small)
                case .running:
                    Button(L10n.Control.stop) { session.stopServing() }
                }
            }
        }
    }

    /// 待受を始める前の画面。ここで初めて使う人に、次に何が起きるかを説明する
    private var idleView: some View {
        VStack(spacing: 12) {
            Image(systemName: "qrcode")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tertiary)
            Text(session.displays.isEmpty ? L10n.Control.noDisplay : L10n.Control.idleHint)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
        }
        .padding(32)
    }

    @ViewBuilder
    private var statusLabel: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(indicatorColor)
                .frame(width: 7, height: 7)
            switch session.serverState {
            case .idle:
                Text(L10n.Menu.stopped).foregroundStyle(.secondary)
            case .starting:
                Text(L10n.Menu.starting).foregroundStyle(.secondary)
            case .running:
                let requests = session.approvalRequests.count
                if requests > 0 {
                    Text(L10n.Status.requests(count: String(requests))).foregroundStyle(.orange)
                } else {
                    Text(L10n.Status.streaming(
                        active: String(session.streams.filter(\.isActive).count),
                        total: String(session.streams.count)
                    ))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                }
            case .failed(let message):
                Text(message)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .help(message)
            }
        }
        .font(.callout)
    }

    private var indicatorColor: Color {
        if case .failed = session.serverState { return .red }
        if !session.approvalRequests.isEmpty { return .orange }
        return session.streams.contains(where: \.isActive) ? .green : .secondary
    }
}
