import 'package:flutter/material.dart';

import '../generated/host_api.g.dart';
import '../generated/strings.dart';
import 'style.dart';

/// 画面収録の許可がないときに出す。許可がないまま黙って動かないことを避けるのが目的。
///
/// 一度尋ねたあとはダイアログを出し直せない OS があるため、経過に応じて導線を切り替える。
/// 許可の状態はコアが見張っていて、変われば自然にこの画面が消える。
class OnboardingView extends StatelessWidget {
  const OnboardingView({super.key, required this.permission, required this.control});

  final ScreenPermission permission;
  final HostUIControl control;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final requestedBefore = permission == ScreenPermission.requestedBefore;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(40),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.desktop_access_disabled_outlined, size: 48, color: context.secondary),
              const SizedBox(height: 20),
              Text(
                L10n.onboarding.title,
                style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              Text(
                requestedBefore ? L10n.onboarding.guidanceAgain : L10n.onboarding.guidanceFirst,
                style: theme.textTheme.bodyMedium?.copyWith(color: context.secondary),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: requestedBefore
                    ? [
                        FilledButton(
                          onPressed: control.openPermissionSettings,
                          child: Text(L10n.onboarding.openSettings),
                        ),
                        OutlinedButton(
                          onPressed: control.relaunch,
                          child: Text(L10n.onboarding.relaunch),
                        ),
                      ]
                    : [
                        FilledButton(
                          onPressed: control.requestPermission,
                          child: Text(L10n.onboarding.request),
                        ),
                      ],
              ),
              const SizedBox(height: 20),
              Text(
                L10n.onboarding.checking,
                style: theme.textTheme.bodySmall?.copyWith(color: context.secondary),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
