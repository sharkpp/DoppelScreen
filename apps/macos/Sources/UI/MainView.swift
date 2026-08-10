import SwiftUI

struct MainView: View {
    let session: SessionController

    var body: some View {
        Group {
            if session.permissionGranted {
                captureView
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

    private var captureView: some View {
        VStack(spacing: 0) {
            PreviewView(renderer: session.previewRenderer)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black)

            // 配信していない間は接続先を出さない（開いていないサーバの URL を見せない）
            if session.captureState == .running {
                Divider()
                ConnectionView(session: session)
            }

            controlBar
        }
    }

    private var controlBar: some View {
        HStack(spacing: 12) {
            Picker("ディスプレイ", selection: Binding(
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

            switch session.captureState {
            case .idle, .failed:
                Button("開始") { session.startCapture() }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.selectedDisplayID == nil)
            case .starting:
                ProgressView().controlSize(.small)
            case .running:
                Button("停止") { session.stopCapture() }
            }

            Spacer()

            statusLabel
        }
        .padding(12)
        .background(.bar)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch session.captureState {
        case .idle:
            Text("停止中").foregroundStyle(.secondary)
        case .starting:
            Text("開始中…").foregroundStyle(.secondary)
        case .running:
            let statistics = session.statistics
            Text("\(statistics.deliveredFrames) frames / \(statistics.droppedFrames) idle")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        case .failed(let message):
            Text(message)
                .foregroundStyle(.red)
                .lineLimit(1)
                .help(message)
        }
    }
}
