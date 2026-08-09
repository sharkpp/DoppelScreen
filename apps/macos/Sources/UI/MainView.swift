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
        .task {
            await session.refreshDisplays()
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

            controlBar
        }
    }

    private var controlBar: some View {
        HStack(spacing: 12) {
            Picker("ディスプレイ", selection: Binding(
                get: { session.selectedDisplayID },
                set: { session.selectedDisplayID = $0 }
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
                Button("開始") { Task { await session.startCapture() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.selectedDisplayID == nil)
            case .starting:
                ProgressView().controlSize(.small)
            case .running:
                Button("停止") { Task { await session.stopCapture() } }
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
