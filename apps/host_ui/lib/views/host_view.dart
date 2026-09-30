import 'package:flutter/material.dart';

import '../generated/host_api.g.dart';
import '../generated/strings.dart';
import '../host_model.dart';
import 'connection_view.dart';
import 'onboarding_view.dart';
import 'style.dart';

/// ホストの操作画面の骨格（SPEC.md §2.3 HostUI）。
///
/// **自分の画面の複製は映さない。** 見えているのは配信中の画面そのものであり、
/// 窓の中にもう一度出す意味がない。ここが受け持つのはペアリングと承認、そして
/// 「いま何が誰へ流れているか」だけ。
class HostView extends StatelessWidget {
  const HostView({super.key, required this.model});

  final HostModel model;

  @override
  Widget build(BuildContext context) {
    final state = model.state;
    // コアから最初の状態が届くまでの一瞬。何も描かない
    if (state == null) return const Scaffold(body: SizedBox.shrink());

    if (state.permission != ScreenPermission.granted) {
      return Scaffold(body: OnboardingView(permission: state.permission, control: model.control));
    }

    return Scaffold(
      body: Column(
        children: [
          _Toolbar(state: state, control: model.control),
          const Divider(height: 1),
          Expanded(
            child: state.server == ServerStatus.running
                ? ConnectionView(state: state, control: model.control)
                : _IdleView(hasDisplays: state.streams.isNotEmpty),
          ),
        ],
      ),
    );
  }
}

/// 待受の開始・停止はこの画面で最も大きい操作なので、上端の右に置く。
/// 状態は同じ並びの左側に出し、押した結果がその場で読めるようにする
class _Toolbar extends StatelessWidget {
  const _Toolbar({required this.state, required this.control});

  final HostState state;
  final HostUIControl control;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: _indicator(context), shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Expanded(child: _statusText(context)),
          const SizedBox(width: 12),
          switch (state.server) {
            ServerStatus.idle || ServerStatus.failed => FilledButton(
                onPressed: state.streams.isEmpty ? null : control.startServing,
                child: Text(L10n.control.start),
              ),
            ServerStatus.starting => const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ServerStatus.running => OutlinedButton(
                onPressed: control.stopServing,
                child: Text(L10n.control.stop),
              ),
          },
        ],
      ),
    );
  }

  Widget _statusText(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyMedium;
    final secondary = style?.copyWith(color: context.secondary);

    return switch (state.server) {
      ServerStatus.idle => Text(L10n.menu.stopped, style: secondary),
      ServerStatus.starting => Text(L10n.menu.starting, style: secondary),
      ServerStatus.running when state.approvalRequests > 0 => Text(
          L10n.status.requests(count: '${state.approvalRequests}'),
          style: style?.copyWith(color: StatusColors.request),
        ),
      ServerStatus.running => Text(
          L10n.status.streaming(active: '${state.activeStreams}', total: '${state.streams.length}'),
          style: secondary?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
        ),
      ServerStatus.failed => Tooltip(
          message: state.serverFailure ?? '',
          child: Text(
            state.serverFailure ?? L10n.menu.failed,
            style: style?.copyWith(color: StatusColors.error),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
    };
  }

  Color _indicator(BuildContext context) {
    if (state.server == ServerStatus.failed) return StatusColors.error;
    if (state.approvalRequests > 0) return StatusColors.request;
    return state.activeStreams > 0 ? StatusColors.streaming : context.secondary.withValues(alpha: 0.5);
  }
}

/// 待受を始める前の画面。初めて使う人に、次に何が起きるかを説明する
class _IdleView extends StatelessWidget {
  const _IdleView({required this.hasDisplays});

  final bool hasDisplays;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.qr_code_2, size: 48, color: context.secondary.withValues(alpha: 0.6)),
              const SizedBox(height: 12),
              Text(
                hasDisplays ? L10n.control.idleHint : L10n.control.noDisplay,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: context.secondary),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
