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
        guard let stream = session.selectedStream else { return "ディスプレイが見つかりません" }
        return switch stream.state {
        case .streaming: nil
        case .idle: session.isServing
            ? "URL を開いたビューアからの接続を待っています"
            : "「配信を開始」で待受を始めます"
        case .awaitingApproval: "接続要求を承認するとここに映ります"
        case .starting: "接続しています…"
        case .failed(let reason): reason
        }
    }

    private var controlBar: some View {
        HStack(spacing: 12) {
            // 選ぶのはプレビューに映す画面。配信そのものは画面ごとに独立している
            Picker("プレビュー", selection: Binding(
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
                Button("配信を開始") { session.startServing() }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.displays.isEmpty)
            case .starting:
                ProgressView().controlSize(.small)
            case .running:
                Button("停止") { session.stopServing() }
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
            Text("停止中").foregroundStyle(.secondary)
        case .starting:
            Text("開始中…").foregroundStyle(.secondary)
        case .running:
            let requests = session.approvalRequests.count
            if requests > 0 {
                Text("\(requests) 件の接続要求").foregroundStyle(.orange)
            } else {
                Text("\(session.streams.filter(\.isActive).count) / \(session.streams.count) 画面を配信中")
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
