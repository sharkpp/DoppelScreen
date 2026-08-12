import SwiftUI

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

    private var servingView: some View {
        VStack(spacing: 0) {
            preview

            // 待ち受けていない間は接続先を出さない（開いていないサーバの URL を見せない）
            if session.isServing {
                Divider()
                ScrollView {
                    ConnectionView(session: session)
                }
                .frame(maxHeight: 240)
            }

            controlBar
        }
    }

    /// 映しているのは「実際に配信しているもの」だけ。承認前・未接続の画面は撮っていないので
    /// 何も出ない（SPEC.md §5.2）。それが分かるように理由を重ねる
    private var preview: some View {
        PreviewView(renderer: session.previewRenderer)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
            .overlay {
                if let message = previewPlaceholder {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                }
            }
    }

    private var previewPlaceholder: String? {
        guard let stream = session.selectedStream else { return L10n.Preview.noDisplay }
        return switch stream.state {
        case .streaming: nil
        case .idle: session.isServing ? L10n.Preview.waitingViewer : L10n.Preview.notServing
        case .awaitingApproval: L10n.Preview.awaitingApproval
        case .starting: L10n.Preview.connecting
        case .failed(let reason): reason
        }
    }

    private var controlBar: some View {
        HStack(spacing: 12) {
            // 選ぶのはプレビューに映す画面。配信そのものは画面ごとに独立している
            Picker(L10n.Control.preview, selection: Binding(
                get: { session.selectedDisplayID },
                set: { session.selectDisplay($0) }
            )) {
                ForEach(session.displays) { display in
                    Text("\(display.name) (\(display.pixelWidth)×\(display.pixelHeight))")
                        .tag(Optional(display.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 320)

            switch session.serverState {
            case .idle, .failed:
                Button(L10n.Control.start) { session.startServing() }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.displays.isEmpty)
            case .starting:
                ProgressView().controlSize(.small)
            case .running:
                Button(L10n.Control.stop) { session.stopServing() }
            }

            Spacer()

            statusLabel
        }
        .padding(12)
        .background(.bar)
    }

    @ViewBuilder
    private var statusLabel: some View {
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
}
