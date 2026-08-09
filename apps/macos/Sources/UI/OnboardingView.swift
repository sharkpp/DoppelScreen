import SwiftUI

/// 画面収録権限が未許諾のときに表示する。
/// 権限がない状態で黙って動かないことを避けるのが目的（docs/STACK.md §2.6 手順 2）。
struct OnboardingView: View {
    let session: SessionController

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "rectangle.on.rectangle.slash")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("画面収録の許可が必要です")
                .font(.title2.weight(.semibold))

            Text("DoppelScreen はこの Mac の画面を配信します。\nシステム設定で「画面収録」を許可してください。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("許可を求める") {
                    session.requestPermission()
                }
                .buttonStyle(.borderedProminent)

                Button("システム設定を開く") {
                    ScreenRecordingPermission.openSystemSettings()
                }
            }

            Text("許可後はアプリの再起動が必要な場合があります。")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
