import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../generated/host_api.g.dart';
import '../generated/strings.dart';
import 'style.dart';

/// 画面ごとの接続先とビューアの状態（SPEC.md §2.3 HostUI）。
///
/// URL は画面ごとに分かれる（SPEC.md §5.2）。別々の画面の URL を別々の端末で開けば、
/// 複数の画面を同時にミラーリングできる。
///
/// **QR がペアリングの本体**で、URL 文字列は QR が読めない環境の代替として併記する。
/// 既定は HTTP（証明書の警告が出ない）で、HTTPS も併せて出す（SPEC.md §5.3）。
///
/// 接続要求の承認もここで行う。**承認するまでその画面のキャプチャは始まらない。**
class ConnectionView extends StatefulWidget {
  const ConnectionView({super.key, required this.state, required this.control});

  final HostState state;
  final HostUIControl control;

  @override
  State<ConnectionView> createState() => _ConnectionViewState();
}

class _ConnectionViewState extends State<ConnectionView> {
  /// インタフェース名の欄。Windows の名前（「vEthernet (Default Switch)」など）は長いので、
  /// 1 行に切り詰めて全体はツールチップで見せる
  static const _interfaceWidth = 112.0;

  /// QR を出している URL。1 つずつしか出さない — 並べると小さくなって読めない
  String? _expanded;
  final _expandedKey = GlobalKey();

  void _toggle(String url) {
    setState(() => _expanded = _expanded == url ? null : url);
    if (_expanded == null) return;
    // QR は大きい。開いたときに全体が見えるところまで送る
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _expandedKey.currentContext;
      if (target == null || !target.mounted) return;
      Scrollable.ensureVisible(
        target,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
        duration: const Duration(milliseconds: 200),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final footnote = Theme.of(context).textTheme.bodySmall;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!state.streams.any((stream) => stream.endpoints.isNotEmpty))
            Text(L10n.connection.noAddress, style: footnote?.copyWith(color: context.secondary))
          else ...[
            _Pairing(state: state, control: widget.control),
            for (final stream in state.streams) ...[
              const SizedBox(height: 16),
              _section(context, stream),
            ],
          ],
          if (state.certificateError case final reason?) ...[
            const SizedBox(height: 14),
            Text(
              L10n.connection.certificateUnavailable(reason: reason),
              style: footnote?.copyWith(color: StatusColors.request),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }

  Widget _section(BuildContext context, DisplayStreamState stream) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(stream.name, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(width: 8),
            Text(
              '${stream.pixelWidth}×${stream.pixelHeight}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: context.secondary,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Align(
                alignment: Alignment.centerRight,
                child: _Status(stream: stream, control: widget.control),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        // インタフェースが複数ある場合は選べるように全件出す（SPEC.md §5.2）
        for (final endpoint in stream.endpoints) ...[
          _row(context, endpoint.interfaceName, endpoint.url),
          if (endpoint.secureUrl case final secureUrl?) _row(context, '', secureUrl),
        ],
      ],
    );
  }

  Widget _row(BuildContext context, String interfaceName, String url) {
    final expanded = _expanded == url;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            SizedBox(
              width: _interfaceWidth,
              child: Tooltip(
                message: interfaceName,
                child: Text(
                  interfaceName,
                  style: monospace.copyWith(fontSize: 12, color: context.secondary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: SelectableText(
                url,
                style: monospace.copyWith(fontSize: 13),
                maxLines: 1,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.qr_code, size: 18),
              tooltip: expanded ? L10n.connection.hideQR : L10n.connection.showQR,
              isSelected: expanded,
              onPressed: () => _toggle(url),
            ),
            IconButton(
              icon: const Icon(Icons.copy_outlined, size: 16),
              tooltip: L10n.connection.copyUrl,
              onPressed: () => Clipboard.setData(ClipboardData(text: url)),
            ),
          ],
        ),
        if (expanded) _qr(context, url),
      ],
    );
  }

  /// QR にはトークンと画面を含む完全な URL が入る。手入力を不要にするのが目的（SPEC.md §5.2）
  Widget _qr(BuildContext context, String url) {
    return Padding(
      key: _expandedKey,
      padding: const EdgeInsets.only(left: _interfaceWidth + 8, top: 4, bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: QrImageView(
              data: url,
              size: 196,
              padding: const EdgeInsets.all(8),
              // 画面の配色に関わらず白地に黒。反転した QR を読めない端末がある
              backgroundColor: Colors.white,
              // URL は短く、誤り訂正を厚くしても密度が上がりすぎない。画面越しに読ませるので余裕を取る
              errorCorrectionLevel: QrErrorCorrectLevel.M,
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 200,
            child: Text(
              L10n.connection.scanHint,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: context.secondary),
            ),
          ),
        ],
      ),
    );
  }
}

/// トークンの状態（SPEC.md §5.2）。期限は全画面で共通なので 1 か所に出す
class _Pairing extends StatelessWidget {
  const _Pairing({required this.state, required this.control});

  final HostState state;
  final HostUIControl control;

  @override
  Widget build(BuildContext context) {
    final caption = Theme.of(context).textTheme.bodySmall;
    final seconds = state.tokenRemainingSeconds;

    return Row(
      children: [
        SelectableText(L10n.pairing.token(token: state.token), style: monospace.copyWith(fontSize: 13)),
        const SizedBox(width: 8),
        Expanded(
          child: Wrap(
            spacing: 8,
            children: [
              Text(
                seconds > 0 ? L10n.pairing.expires(seconds: '$seconds') : L10n.pairing.expired,
                style: caption?.copyWith(
                  color: context.secondary,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              if (state.tokenRegeneratedAfterFailures)
                Text(L10n.pairing.rejected, style: caption?.copyWith(color: StatusColors.request)),
            ],
          ),
        ),
        TextButton(onPressed: control.regenerateToken, child: Text(L10n.pairing.regenerate)),
      ],
    );
  }
}

class _Status extends StatelessWidget {
  const _Status({required this.stream, required this.control});

  final DisplayStreamState stream;
  final HostUIControl control;

  @override
  Widget build(BuildContext context) {
    final footnote = Theme.of(context).textTheme.bodySmall;
    final secondary = footnote?.copyWith(color: context.secondary);
    final address = stream.peerAddress ?? '';
    final id = stream.displayId;

    Widget line(List<Widget> children) => Wrap(
          alignment: WrapAlignment.end,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 4,
          children: children,
        );

    return switch (stream.status) {
      StreamStatus.idle => Text(L10n.connection.idle, style: secondary, textAlign: TextAlign.end),

      // トークンだけでは接続を成立させない。ここが無人アクセスを防ぐ要（SPEC.md §5.2）
      StreamStatus.awaitingApproval => line([
          Text(L10n.connection.request(address: address), style: footnote?.copyWith(color: StatusColors.request)),
          FilledButton(onPressed: () => control.approve(id), child: Text(L10n.connection.approve)),
          OutlinedButton(onPressed: () => control.reject(id), child: Text(L10n.connection.reject)),
        ]),

      StreamStatus.starting => line([
          const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2)),
          Text(L10n.connection.connecting(address: address), style: secondary),
        ]),

      StreamStatus.streaming => line([
          Text(L10n.connection.streaming(address: address), style: footnote?.copyWith(color: StatusColors.streaming)),
          // ビューアの表示サイズへ追従した実効解像度（SPEC.md §7.1）
          if (stream.activeWidth != null && stream.activeHeight != null)
            Text(
              '${stream.activeWidth}×${stream.activeHeight}',
              style: secondary?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
            ),
          // 画質はビューアが選ぶ（SPEC.md §7.2）。ホストは今の設定を映すだけ
          Text(L10n.connection.quality(preset: _qualityName(stream.quality)), style: secondary),
          TextButton(onPressed: () => control.disconnect(id), child: Text(L10n.connection.disconnect)),
        ]),

      StreamStatus.failed => Tooltip(
          message: stream.failure ?? '',
          child: Text(
            stream.failure ?? '',
            style: secondary,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.end,
          ),
        ),
    };
  }

  static String _qualityName(StreamQuality quality) => switch (quality) {
        StreamQuality.sharp => L10n.quality.sharp,
        StreamQuality.balanced => L10n.quality.balanced,
        StreamQuality.smooth => L10n.quality.smooth,
      };
}
