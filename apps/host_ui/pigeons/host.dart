// ホスト UI（Dart）とネイティブのコアの境界（docs/adr/0002-host-ui-flutter.md）。
//
// ここが正で、各言語の出力は生成物。直したら apps/host_ui で
//   dart run pigeon --input pigeons/host.dart
// を実行する。
//
// **境界を跨ぐのは状態と操作だけ。** フレームも SDP も Dart には入れない。
// コアは状態を丸ごと送り直す（差分は持たない）。変化したときと、トークンの残り時間を
// 数えるための 1 秒ごと。
import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/generated/host_api.g.dart',
    swiftOut: '../macos/Sources/HostUI/HostAPI.g.swift',
    swiftOptions: SwiftOptions(errorClassName: 'HostAPIError'),
    cppHeaderOut: '../windows/src/generated/host_api.g.h',
    cppSourceOut: '../windows/src/generated/host_api.g.cpp',
    cppOptions: CppOptions(namespace: 'doppelscreen::ui', headerIncludePath: 'host_api.g.h'),
  ),
)
/// 画面収録の許可。許可の仕組みを持たない OS は常に `granted`
enum ScreenPermission {
  granted,

  /// まだ尋ねていない。尋ねればダイアログが出る
  notRequested,

  /// 一度尋ねている。以後はシステム設定で許可してもらうしかない
  requestedBefore,
}

enum ServerStatus { idle, starting, running, failed }

enum StreamStatus { idle, awaitingApproval, starting, streaming, failed }

/// ビューアが選んだ画質（SPEC.md §7.2）
enum StreamQuality { sharp, balanced, smooth }

/// ビューアに渡す接続先。画面ごと・インタフェースごとに 1 件（SPEC.md §5.2）
class EndpointState {
  EndpointState(this.interfaceName, this.url, this.secureUrl);

  String interfaceName;

  /// 既定は HTTP（SPEC.md §5.3）
  String url;

  /// 証明書を用意できなかったときは null
  String? secureUrl;
}

/// 画面 1 枚ぶんの配信
class DisplayStreamState {
  DisplayStreamState(
    this.displayId,
    this.name,
    this.pixelWidth,
    this.pixelHeight,
    this.status,
    this.peerAddress,
    this.failure,
    this.activeWidth,
    this.activeHeight,
    this.quality,
    this.endpoints,
  );

  int displayId;
  String name;
  int pixelWidth;
  int pixelHeight;
  StreamStatus status;

  /// 承認待ち・接続中・配信中のビューアのアドレス
  String? peerAddress;

  /// `failed` の理由。コアが表示言語で組み立てた文言
  String? failure;

  /// ビューアの表示サイズへ追従した実効解像度（SPEC.md §7.1）。配信中だけ
  int? activeWidth;
  int? activeHeight;
  StreamQuality quality;
  List<EndpointState> endpoints;
}

class HostState {
  HostState(
    this.permission,
    this.server,
    this.serverFailure,
    this.token,
    this.tokenRemainingSeconds,
    this.tokenRegeneratedAfterFailures,
    this.certificateError,
    this.streams,
  );

  ScreenPermission permission;
  ServerStatus server;

  /// `failed` の理由
  String? serverFailure;

  /// 接続トークン（SPEC.md §5.2）。全画面で共通
  String token;
  int tokenRemainingSeconds;

  /// 直近の作り直しが「誤りが続いたから」だったか
  bool tokenRegeneratedAfterFailures;

  /// 証明書を用意できず HTTP だけで動いているときの理由
  String? certificateError;

  /// ディスプレイの並び順どおり
  List<DisplayStreamState> streams;
}

/// UI → コア
@HostApi()
abstract class HostUIControl {
  /// 起動直後に 1 回だけ取りに行く。以後は `HostUIEvents.stateChanged` が届く
  HostState currentState();

  void startServing();
  void stopServing();
  void regenerateToken();

  /// **承認するまでその画面のキャプチャは始まらない**（SPEC.md §5.2）
  void approve(int displayId);
  void reject(int displayId);
  void disconnect(int displayId);

  /// 画面収録の許可を求める。許可の仕組みを持たない OS では何もしない
  void requestPermission();
  void openPermissionSettings();

  /// 許可を反映するための再起動
  void relaunch();
}

/// コア → UI
@FlutterApi()
abstract class HostUIEvents {
  void stateChanged(HostState state);
}
