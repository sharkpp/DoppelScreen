import SwiftUI

/// 画面ごとの接続先とビューアの状態（SPEC.md §2.3 HostUI）。
///
/// URL は画面ごとに分かれる（SPEC.md §5.2）。別々の画面の URL を別々の端末で開けば、
/// 複数の画面を同時にミラーリングできる。
///
/// 接続要求の承認もここで行う。**承認するまでその画面のキャプチャは始まらない。**
struct ConnectionView: View {
    let session: SessionController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if session.endpoints.isEmpty {
                Text("LAN のアドレスが見つかりません")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(session.streams, id: \.id) { stream in
                    section(for: stream)
                }
            }

            if let certificateError = session.certificateError {
                Text("HTTPS は使えません: \(certificateError)")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quinary)
    }

    private func section(for stream: DisplayStream) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(stream.display.name)
                    .font(.callout.weight(.semibold))
                Text("\(stream.display.pixelWidth)×\(stream.display.pixelHeight)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                status(for: stream)
            }

            // インタフェースが複数ある場合は選べるように全件出す（SPEC.md §5.2）
            ForEach(session.endpoints(for: stream.id)) { endpoint in
                // 既定は HTTP。証明書の警告が出ない（SPEC.md §5.3）
                row(interfaceName: endpoint.interfaceName, url: endpoint.url)
                if let secureURL = endpoint.secureURL {
                    row(interfaceName: "", url: secureURL)
                }
            }
        }
    }

    private func row(interfaceName: String, url: String) -> some View {
        HStack(spacing: 8) {
            Text(interfaceName)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)

            Text(url)
                .font(.body.monospaced())
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("URL をコピー")

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func status(for stream: DisplayStream) -> some View {
        switch stream.state {
        case .idle:
            Text("ビューア未接続").font(.footnote).foregroundStyle(.secondary)

        case .awaitingApproval(let address):
            // トークンだけでは接続を成立させない。ここが無人アクセスを防ぐ要（SPEC.md §5.2）
            HStack(spacing: 8) {
                Text("\(address) から接続要求")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                Button("承認") { stream.approve() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("拒否") { stream.reject() }
                    .controlSize(.small)
            }

        case .starting(let address):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("\(address) と接続中").font(.footnote).foregroundStyle(.secondary)
            }

        case .streaming(let address):
            HStack(spacing: 8) {
                Text("\(address) へ配信中").font(.footnote).foregroundStyle(.green)
                // ビューアの表示サイズへ追従した実効解像度（SPEC.md §7.1）
                if let configuration = stream.activeConfiguration {
                    Text("\(configuration.width)×\(configuration.height)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Button("切断") { stream.disconnect() }
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
