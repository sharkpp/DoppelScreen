import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:host_ui/generated/host_api.g.dart';
import 'package:host_ui/generated/strings.dart';
import 'package:host_ui/host_model.dart';
import 'package:host_ui/main.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// コアの代わり。受けた操作を記録し、渡された状態を返すだけ
class FakeControl implements HostUIControl {
  FakeControl(this.state);

  HostState state;
  final calls = <String>[];

  @override
  Future<HostState> currentState() async => state;
  @override
  Future<void> startServing() async => calls.add('start');
  @override
  Future<void> stopServing() async => calls.add('stop');
  @override
  Future<void> regenerateToken() async => calls.add('regenerate');
  @override
  Future<void> approve(int displayId) async => calls.add('approve $displayId');
  @override
  Future<void> reject(int displayId) async => calls.add('reject $displayId');
  @override
  Future<void> disconnect(int displayId) async => calls.add('disconnect $displayId');
  @override
  Future<void> requestPermission() async => calls.add('requestPermission');
  @override
  Future<void> openPermissionSettings() async => calls.add('openPermissionSettings');
  @override
  Future<void> relaunch() async => calls.add('relaunch');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

HostState hostState({
  ScreenPermission permission = ScreenPermission.granted,
  ServerStatus server = ServerStatus.running,
  StreamStatus status = StreamStatus.idle,
}) {
  return HostState(
    permission: permission,
    server: server,
    token: 'abcd2345',
    tokenRemainingSeconds: 120,
    tokenRegeneratedAfterFailures: false,
    streams: [
      DisplayStreamState(
        displayId: 7,
        name: 'Built-in',
        pixelWidth: 2880,
        pixelHeight: 1800,
        status: status,
        peerAddress: status == StreamStatus.idle ? null : '192.168.1.20',
        quality: StreamQuality.sharp,
        endpoints: [
          EndpointState(
            interfaceName: 'en0',
            url: 'http://192.168.1.10:8422/?d=7#abcd2345',
            secureUrl: 'https://192.168.1.10:8423/?d=7#abcd2345',
          ),
        ],
      ),
    ],
  );
}

Future<FakeControl> pumpHost(WidgetTester tester, HostState state) async {
  tester.view.physicalSize = const Size(1360, 1040);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);

  final control = FakeControl(state);
  final model = HostModel(control: control);
  addTearDown(model.dispose);
  await tester.pumpWidget(HostApp(model: model));
  await tester.pumpAndSettle();
  return control;
}

void main() {
  testWidgets('承認待ちの画面に承認と拒否が出て、押すとその画面の ID でコアへ届く', (tester) async {
    final control = await pumpHost(tester, hostState(status: StreamStatus.awaitingApproval));

    expect(find.text(L10n.status.requests(count: '1')), findsOneWidget);
    await tester.tap(find.text(L10n.connection.approve));
    await tester.tap(find.text(L10n.connection.reject));
    expect(control.calls, ['approve 7', 'reject 7']);
  });

  testWidgets('QR は押した URL の分だけ開き、もう一度押すと閉じる', (tester) async {
    await pumpHost(tester, hostState());

    expect(find.byType(QrImageView), findsNothing);
    await tester.tap(find.byTooltip(L10n.connection.showQR).first);
    await tester.pumpAndSettle();
    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.text(L10n.connection.scanHint), findsOneWidget);

    await tester.tap(find.byTooltip(L10n.connection.hideQR));
    await tester.pumpAndSettle();
    expect(find.byType(QrImageView), findsNothing);
  });

  testWidgets('待受前は開始ボタンだけで、接続先は出さない', (tester) async {
    final control = await pumpHost(tester, hostState(server: ServerStatus.idle));

    expect(find.textContaining('http://'), findsNothing);
    await tester.tap(find.text(L10n.control.start));
    expect(control.calls, ['start']);
  });

  testWidgets('一度尋ねた後は、許可を求める代わりにシステム設定と再起動を出す', (tester) async {
    final control = await pumpHost(tester, hostState(permission: ScreenPermission.requestedBefore));

    expect(find.text(L10n.onboarding.request), findsNothing);
    // 既定の窓の大きさでは説明が長く、ボタンはスクロールした先にある
    await tester.ensureVisible(find.text(L10n.onboarding.relaunch));
    await tester.tap(find.text(L10n.onboarding.openSettings));
    await tester.tap(find.text(L10n.onboarding.relaunch));
    expect(control.calls, ['openPermissionSettings', 'relaunch']);
  });

  test('表示言語は地域を無視して選び、合わなければ基準言語へ落とす', () {
    expect(resolveLanguage(const [Locale('en', 'GB')]), 'en');
    expect(resolveLanguage(const [Locale('fr'), Locale('ja', 'JP')]), 'ja');
    expect(resolveLanguage(const [Locale('fr')]), 'ja');
  });
}
