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

            Text(L10n.Onboarding.title)
                .font(.title2.weight(.semibold))

            Text(guidance)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)

            HStack(spacing: 12) {
                if session.hasRequestedPermissionBefore {
                    Button(L10n.Onboarding.openSettings) {
                        ScreenRecordingPermission.openSystemSettings()
                    }
                    .buttonStyle(.borderedProminent)

                    Button(L10n.Onboarding.relaunch) {
                        ScreenRecordingPermission.relaunch()
                    }
                } else {
                    Button(L10n.Onboarding.request) {
                        session.requestPermission()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            Text(L10n.Onboarding.checking)
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var guidance: String {
        session.hasRequestedPermissionBefore ? L10n.Onboarding.guidanceAgain : L10n.Onboarding.guidanceFirst
    }
}
