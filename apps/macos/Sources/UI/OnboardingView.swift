import SwiftUI

/// 画面収録権限が未許諾のときに表示する。
/// 権限がない状態で黙って動かないことを避けるのが目的（docs/STACK.md §2.6 手順 2）。
///
/// 一度プロンプトを出したあとは `CGRequestScreenCaptureAccess()` が無反応になるため、
/// 経過に応じて導線を切り替える。
struct OnboardingView: View {
    let session: SessionController

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "rectangle.on.rectangle.slash")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("画面収録の許可が必要です")
                .font(.title2.weight(.semibold))

            Text(guidance)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)

            HStack(spacing: 12) {
                if session.hasRequestedPermissionBefore {
                    Button("システム設定を開く") {
                        ScreenRecordingPermission.openSystemSettings()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("再起動して反映") {
                        ScreenRecordingPermission.relaunch()
                    }
                } else {
                    Button("許可を求める") {
                        session.requestPermission()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            Text("現在の状態: 未許可（1 秒ごとに再確認しています）")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var guidance: String {
        if session.hasRequestedPermissionBefore {
            """
            システム設定の「プライバシーとセキュリティ  ›  画面収録」で DoppelScreen を許可してください。
            許可しても実行中のアプリには反映されないため、そのあと再起動が必要です。

            すでに許可済みに見えるのに反映されない場合は、リストから DoppelScreen を一度削除して\
            追加し直してください（開発ビルドは署名が毎回変わるため、別アプリとして扱われます）。
            """
        } else {
            """
            DoppelScreen はこの Mac の画面を配信します。
            「許可を求める」を押し、表示されるダイアログで許可してください。
            """
        }
    }
}
