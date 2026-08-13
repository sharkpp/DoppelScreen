import SwiftUI

/// 「DoppelScreen について」ウィンドウの識別子
enum AboutWindow {
    static let id = "about"
}

/// アプリの素性を出すだけの画面。
///
/// Dock アイコンを持たない（`LSUIElement`）ため標準のアプリメニューが無く、
/// 「◯◯ について」を OS が用意してくれない。メニューバーから開く形で自前で持つ。
struct AboutView: View {
    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            // `NSApp.applicationIconImage` は Dock タイルを持たないアプリでは
            // 差し替え前の仮画像を返すことがある。バンドルの .icns を直接読む
            Image(nsImage: NSImage(named: "AppIcon") ?? NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)

            VStack(alignment: .leading, spacing: 8) {
                Text("DoppelScreen")
                    .font(.title2.weight(.semibold))

                Text(L10n.About.version(version: Self.version, build: Self.build))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)

                Text(L10n.About.tagline)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                Text(Self.copyright)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)

                HStack(spacing: 12) {
                    Text(L10n.About.license)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    // 依存のライセンス表示はバンドルに入れている（THIRD-PARTY-NOTICES.md）
                    if let licenses = Self.licensesURL {
                        Button(L10n.About.showLicenses) {
                            NSWorkspace.shared.open(licenses)
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 460, alignment: .leading)
    }

    private static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    private static var copyright: String {
        Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String ?? ""
    }

    private static var licensesURL: URL? {
        guard let url = Bundle.main.resourceURL?.appending(path: "Licenses"),
              FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url
    }
}
