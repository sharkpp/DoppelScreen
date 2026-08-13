import SwiftUI

/// 画面ごとの接続先とビューアの状態（SPEC.md §2.3 HostUI）。
///
/// URL は画面ごとに分かれる（SPEC.md §5.2）。別々の画面の URL を別々の端末で開けば、
/// 複数の画面を同時にミラーリングできる。
///
/// **QR がペアリングの本体**で、URL 文字列は QR が読めない環境の代替として併記する。
/// 既定は HTTP（証明書の警告が出ない）で、HTTPS も併せて出す（SPEC.md §5.3）。
///
/// 接続要求の承認もここで行う。**承認するまでその画面のキャプチャは始まらない。**
struct ConnectionView: View {
    let session: SessionController

    /// QR を出しているエンドポイント。1 つずつしか出さない — 並べると小さくなって読めない
    @State private var expanded: String?

    var body: some View {
        // QR は大きい。開いたときに全体が見えるところまで自分で送る（下端を合わせる）
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if session.endpoints.isEmpty {
                        Text(L10n.Connection.noAddress)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        pairing
                        ForEach(session.streams, id: \.id) { stream in
                            section(for: stream)
                        }
                    }

                    if let certificateError = session.certificateError {
                        Text(L10n.Connection.certificateUnavailable(reason: certificateError))
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: expanded) { _, url in
                guard let url else { return }
                withAnimation { proxy.scrollTo(url, anchor: .bottom) }
            }
        }
    }

    /// トークンの状態（SPEC.md §5.2）。期限は全画面で共通なので 1 か所に出す
    private var pairing: some View {
        HStack(spacing: 8) {
            Text(L10n.Pairing.token(token: session.pairingSnapshot.token))
                .font(.callout.monospaced())
                .textSelection(.enabled)

            let seconds = Int(session.pairingSnapshot.remaining.components.seconds)
            Text(seconds > 0 ? L10n.Pairing.expires(seconds: String(seconds)) : L10n.Pairing.expired)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            if session.pairingSnapshot.regeneratedAfterFailures {
                Text(L10n.Pairing.rejected)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Spacer(minLength: 8)

            Button(L10n.Pairing.regenerate) { session.regenerateToken() }
                .controlSize(.small)
        }
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

    @ViewBuilder
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
                expanded = expanded == url ? nil : url
            } label: {
                Image(systemName: "qrcode")
            }
            .buttonStyle(.borderless)
            .help(expanded == url ? L10n.Connection.hideQR : L10n.Connection.showQR)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help(L10n.Connection.copyUrl)

            Spacer(minLength: 0)
        }

        if expanded == url {
            qr(for: url)
        }
    }

    /// QR にはトークンと画面を含む完全な URL が入る。手入力を不要にするのが目的（SPEC.md §5.2）
    @ViewBuilder
    private func qr(for url: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if let image = QRCode.image(for: url, size: 180) {
                Image(nsImage: image)
                    // 補間するとモジュールの境界がぼけて読み取り率が落ちる
                    .interpolation(.none)
                    .frame(width: 180, height: 180)
                    .padding(8)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            Text(L10n.Connection.scanHint)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 200, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(.leading, 64)
        .padding(.vertical, 4)
        // 開いた QR へスクロールするための目印（`expanded` と同じ URL）
        .id(url)
    }

    @ViewBuilder
    private func status(for stream: DisplayStream) -> some View {
        switch stream.state {
        case .idle:
            Text(L10n.Connection.idle).font(.footnote).foregroundStyle(.secondary)

        case .awaitingApproval(let address):
            // トークンだけでは接続を成立させない。ここが無人アクセスを防ぐ要（SPEC.md §5.2）
            HStack(spacing: 8) {
                Text(L10n.Connection.request(address: address))
                    .font(.footnote)
                    .foregroundStyle(.orange)
                Button(L10n.Connection.approve) { stream.approve() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button(L10n.Connection.reject) { stream.reject() }
                    .controlSize(.small)
            }

        case .starting(let address):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(L10n.Connection.connecting(address: address))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

        case .streaming(let address):
            HStack(spacing: 8) {
                Text(L10n.Connection.streaming(address: address))
                    .font(.footnote)
                    .foregroundStyle(.green)
                // ビューアの表示サイズへ追従した実効解像度（SPEC.md §7.1）
                if let configuration = stream.activeConfiguration {
                    Text("\(configuration.width)×\(configuration.height)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                // 画質はビューアが選ぶ（SPEC.md §7.2）。ホストは今の設定を映すだけ
                Text(L10n.Connection.quality(preset: stream.quality.localizedName))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(L10n.Connection.disconnect) { stream.disconnect() }
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
