import SwiftUI

/// 接続先の URL とビューアの状態（SPEC.md §2.3 HostUI）。
///
/// M0 では URL の文字列表示のみ。QR とホスト承認は M2。
struct ConnectionView: View {
    let session: SessionController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("接続先")
                    .font(.callout.weight(.semibold))
                Spacer()
                viewerStatus
            }

            if session.endpoints.isEmpty {
                Text("LAN のアドレスが見つかりません")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                // インタフェースが複数ある場合は選べるように全件出す（SPEC.md §5.2）
                ForEach(session.endpoints) { endpoint in
                    HStack(spacing: 8) {
                        Text(endpoint.interfaceName)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .frame(width: 56, alignment: .leading)

                        Text(endpoint.url)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(endpoint.url, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("URL をコピー")

                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quinary)
    }

    @ViewBuilder
    private var viewerStatus: some View {
        switch session.viewerState {
        case .none:
            Text("ビューア未接続").font(.footnote).foregroundStyle(.secondary)
        case .negotiating(let address):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("\(address) と接続中").font(.footnote).foregroundStyle(.secondary)
            }
        case .streaming(let address):
            HStack(spacing: 8) {
                Text("\(address) へ配信中").font(.footnote).foregroundStyle(.green)
                Button("切断") { session.disconnectViewer() }
                    .buttonStyle(.borderless)
            }
        case .failed(let reason):
            Text(reason)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(reason)
        }
    }
}
