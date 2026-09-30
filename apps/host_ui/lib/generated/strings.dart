// 自動生成 — 直接編集しない。i18n/*.yaml を直して `make i18n` を実行する。

import 'dart:ui' show Locale, PlatformDispatcher;

const _base = "ja";

const _messages = <String, Map<String, String>>{
  "ja": {
    "host.about.license": "本体は MIT ライセンスです",
    "host.about.showLicenses": "依存のライセンス表示",
    "host.about.tagline": "この Mac の画面を、同じ LAN の別の端末のブラウザへ複製します。",
    "host.about.version": "バージョン {version}（ビルド {build}）",
    "host.connection.approve": "承認",
    "host.connection.certificateUnavailable": "HTTPS は使えません: {reason}",
    "host.connection.connecting": "{address} と接続中",
    "host.connection.copyUrl": "URL をコピー",
    "host.connection.disconnect": "切断",
    "host.connection.hideQR": "QR を隠す",
    "host.connection.idle": "ビューア未接続",
    "host.connection.noAddress": "LAN のアドレスが見つかりません",
    "host.connection.quality": "画質: {preset}",
    "host.connection.reject": "拒否",
    "host.connection.request": "{address} から接続要求",
    "host.connection.scanHint": "この QR をビューアにする端末のカメラで読んでください",
    "host.connection.showQR": "QR を表示",
    "host.connection.streaming": "{address} へ配信中",
    "host.control.idleHint": "「配信を開始」を押すと、画面ごとの QR と URL が出ます。\n手元の端末のカメラで QR を読み、ここで承認すると画面が映ります。",
    "host.control.noDisplay": "ディスプレイが見つかりません",
    "host.control.start": "配信を開始",
    "host.control.stop": "配信を停止",
    "host.failure.answerRejected": "ビューアの応答を受け付けられませんでした",
    "host.failure.certificateCreationFailed": "証明書を生成できませんでした",
    "host.failure.controlUnavailable": "制御チャネルを生成できません",
    "host.failure.displayNotFound": "ディスプレイ {id} が見つかりません",
    "host.failure.keyCreationFailed": "秘密鍵を生成できませんでした: {message}",
    "host.failure.keychain": "キーチェーン操作に失敗しました（{operation}: {message}）",
    "host.failure.peerFailed": "接続に失敗しました",
    "host.failure.peerUnavailable": "PeerConnection を生成できません",
    "host.failure.viewerDisconnected": "ビューアとの接続が切れました",
    "host.failure.viewerLeft": "ビューアが切断しました",
    "host.failure.viewerPageMissing": "ビューアページがバンドルに含まれていません（apps/web のビルドを確認してください）",
    "host.menu.about": "DoppelScreen について",
    "host.menu.failed": "エラー",
    "host.menu.quit": "DoppelScreen を終了",
    "host.menu.requests": "{count} 件の接続要求",
    "host.menu.serving": "待受中（{count} 画面を配信）",
    "host.menu.showWindow": "ウィンドウを表示",
    "host.menu.starting": "開始中…",
    "host.menu.stopped": "停止中",
    "host.onboarding.checking": "現在の状態: 未許可（1 秒ごとに再確認しています）",
    "host.onboarding.guidanceAgain": "システム設定の「プライバシーとセキュリティ  ›  画面収録」で DoppelScreen を許可してください。\n許可しても実行中のアプリには反映されないため、そのあと再起動が必要です。\n\nすでに許可済みに見えるのに反映されない場合は、リストから DoppelScreen を一度削除して追加し直してください（開発ビルドは署名が毎回変わるため、別アプリとして扱われます）。",
    "host.onboarding.guidanceFirst": "DoppelScreen はこの Mac の画面を配信します。\n「許可を求める」を押し、表示されるダイアログで許可してください。",
    "host.onboarding.openSettings": "システム設定を開く",
    "host.onboarding.relaunch": "再起動して反映",
    "host.onboarding.request": "許可を求める",
    "host.onboarding.title": "画面収録の許可が必要です",
    "host.pairing.expired": "期限切れ。作り直してください",
    "host.pairing.expires": "あと {seconds} 秒で新しくなります",
    "host.pairing.regenerate": "作り直す",
    "host.pairing.rejected": "トークンの誤りが続いたため作り直しました",
    "host.pairing.token": "接続トークン: {token}",
    "host.quality.balanced": "バランス",
    "host.quality.sharp": "文字くっきり",
    "host.quality.smooth": "なめらか",
    "host.status.requests": "{count} 件の接続要求",
    "host.status.streaming": "{active} / {total} 画面を配信中",
  },
  "en": {
    "host.about.license": "DoppelScreen itself is MIT licensed",
    "host.about.showLicenses": "Third-party licenses",
    "host.about.tagline": "Mirrors this Mac's screen to a browser on another device on the same LAN.",
    "host.about.version": "Version {version} (build {build})",
    "host.connection.approve": "Approve",
    "host.connection.certificateUnavailable": "HTTPS unavailable: {reason}",
    "host.connection.connecting": "Connecting to {address}",
    "host.connection.copyUrl": "Copy URL",
    "host.connection.disconnect": "Disconnect",
    "host.connection.hideQR": "Hide QR",
    "host.connection.idle": "No viewer connected",
    "host.connection.noAddress": "No LAN address found",
    "host.connection.quality": "Quality: {preset}",
    "host.connection.reject": "Reject",
    "host.connection.request": "Connection request from {address}",
    "host.connection.scanHint": "Scan this QR with the camera of the device you want to view on",
    "host.connection.showQR": "Show QR",
    "host.connection.streaming": "Streaming to {address}",
    "host.control.idleHint": "Press \"Start streaming\" to show a QR code and URL for each display.\nScan the QR with the device you want to view on, then approve it here.",
    "host.control.noDisplay": "No display found",
    "host.control.start": "Start streaming",
    "host.control.stop": "Stop streaming",
    "host.failure.answerRejected": "The viewer's answer could not be accepted",
    "host.failure.certificateCreationFailed": "Could not create the certificate",
    "host.failure.controlUnavailable": "Could not create the control channel",
    "host.failure.displayNotFound": "Display {id} was not found",
    "host.failure.keyCreationFailed": "Could not create the private key: {message}",
    "host.failure.keychain": "Keychain operation failed ({operation}: {message})",
    "host.failure.peerFailed": "The connection failed",
    "host.failure.peerUnavailable": "Could not create a PeerConnection",
    "host.failure.viewerDisconnected": "The connection to the viewer was lost",
    "host.failure.viewerLeft": "The viewer disconnected",
    "host.failure.viewerPageMissing": "The viewer page is missing from the bundle (check that apps/web was built)",
    "host.menu.about": "About DoppelScreen",
    "host.menu.failed": "Error",
    "host.menu.quit": "Quit DoppelScreen",
    "host.menu.requests": "{count} connection request(s)",
    "host.menu.serving": "Listening ({count} display(s) streaming)",
    "host.menu.showWindow": "Show Window",
    "host.menu.starting": "Starting…",
    "host.menu.stopped": "Stopped",
    "host.onboarding.checking": "Current state: not granted (re-checking every second)",
    "host.onboarding.guidanceAgain": "Allow DoppelScreen under System Settings › Privacy & Security › Screen Recording.\nGranting it does not apply to a running app, so a relaunch is needed afterwards.\n\nIf it looks granted but still has no effect, remove DoppelScreen from the list and add it again (development builds are signed differently each time, so they are treated as a different app).",
    "host.onboarding.guidanceFirst": "DoppelScreen streams this Mac's screen.\nPress \"Request permission\" and allow it in the dialog that appears.",
    "host.onboarding.openSettings": "Open System Settings",
    "host.onboarding.relaunch": "Relaunch to apply",
    "host.onboarding.request": "Request permission",
    "host.onboarding.title": "Screen Recording permission is required",
    "host.pairing.expired": "Expired — regenerate it",
    "host.pairing.expires": "Renews in {seconds}s",
    "host.pairing.regenerate": "Regenerate",
    "host.pairing.rejected": "Regenerated after repeated wrong tokens",
    "host.pairing.token": "Pairing token: {token}",
    "host.quality.balanced": "Balanced",
    "host.quality.sharp": "Sharp text",
    "host.quality.smooth": "Smooth",
    "host.status.requests": "{count} connection request(s)",
    "host.status.streaming": "{active} / {total} display(s) streaming",
  },
};

/// OS の表示言語から 1 つ選ぶ。地域まで一致しなくてよい（`en-GB` は `en` として扱う）。
/// どれとも合わなければ基準言語へ落とす（ネイティブ側の .lproj と同じ振る舞い）。
String resolveLanguage(Iterable<Locale> preferred) {
  for (final locale in preferred) {
    if (_messages.containsKey(locale.languageCode)) return locale.languageCode;
  }
  return _base;
}

final String language = resolveLanguage(PlatformDispatcher.instance.locales);

final Map<String, String> _table = _messages[language]!;

final _placeholder = RegExp(r'\{([A-Za-z][A-Za-z0-9]*)\}');

String _format(String text, Map<String, String> values) =>
    text.replaceAllMapped(_placeholder, (match) => values[match[1]] ?? match[0]!);

/// 文言。プレースホルダを持つものだけ関数になる
abstract final class L10n {
  static const about = L10nAbout._();
  static const connection = L10nConnection._();
  static const control = L10nControl._();
  static const failure = L10nFailure._();
  static const menu = L10nMenu._();
  static const onboarding = L10nOnboarding._();
  static const pairing = L10nPairing._();
  static const quality = L10nQuality._();
  static const status = L10nStatus._();
}

final class L10nAbout {
  const L10nAbout._();

  /// 本体は MIT ライセンスです
  String get license => _table["host.about.license"]!;

  /// 依存のライセンス表示
  String get showLicenses => _table["host.about.showLicenses"]!;

  /// この Mac の画面を、同じ LAN の別の端末のブラウザへ複製します。
  String get tagline => _table["host.about.tagline"]!;

  /// バージョン {version}（ビルド {build}）
  String version({required String version, required String build}) =>
      _format(_table["host.about.version"]!, {"version": version, "build": build});
}

final class L10nConnection {
  const L10nConnection._();

  /// 承認
  String get approve => _table["host.connection.approve"]!;

  /// HTTPS は使えません: {reason}
  String certificateUnavailable({required String reason}) =>
      _format(_table["host.connection.certificateUnavailable"]!, {"reason": reason});

  /// {address} と接続中
  String connecting({required String address}) =>
      _format(_table["host.connection.connecting"]!, {"address": address});

  /// URL をコピー
  String get copyUrl => _table["host.connection.copyUrl"]!;

  /// 切断
  String get disconnect => _table["host.connection.disconnect"]!;

  /// QR を隠す
  String get hideQR => _table["host.connection.hideQR"]!;

  /// ビューア未接続
  String get idle => _table["host.connection.idle"]!;

  /// LAN のアドレスが見つかりません
  String get noAddress => _table["host.connection.noAddress"]!;

  /// 画質: {preset}
  String quality({required String preset}) =>
      _format(_table["host.connection.quality"]!, {"preset": preset});

  /// 拒否
  String get reject => _table["host.connection.reject"]!;

  /// {address} から接続要求
  String request({required String address}) =>
      _format(_table["host.connection.request"]!, {"address": address});

  /// この QR をビューアにする端末のカメラで読んでください
  String get scanHint => _table["host.connection.scanHint"]!;

  /// QR を表示
  String get showQR => _table["host.connection.showQR"]!;

  /// {address} へ配信中
  String streaming({required String address}) =>
      _format(_table["host.connection.streaming"]!, {"address": address});
}

final class L10nControl {
  const L10nControl._();

  /// 「配信を開始」を押すと、画面ごとの QR と URL が出ます。
  String get idleHint => _table["host.control.idleHint"]!;

  /// ディスプレイが見つかりません
  String get noDisplay => _table["host.control.noDisplay"]!;

  /// 配信を開始
  String get start => _table["host.control.start"]!;

  /// 配信を停止
  String get stop => _table["host.control.stop"]!;
}

final class L10nFailure {
  const L10nFailure._();

  /// ビューアの応答を受け付けられませんでした
  String get answerRejected => _table["host.failure.answerRejected"]!;

  /// 証明書を生成できませんでした
  String get certificateCreationFailed => _table["host.failure.certificateCreationFailed"]!;

  /// 制御チャネルを生成できません
  String get controlUnavailable => _table["host.failure.controlUnavailable"]!;

  /// ディスプレイ {id} が見つかりません
  String displayNotFound({required String id}) =>
      _format(_table["host.failure.displayNotFound"]!, {"id": id});

  /// 秘密鍵を生成できませんでした: {message}
  String keyCreationFailed({required String message}) =>
      _format(_table["host.failure.keyCreationFailed"]!, {"message": message});

  /// キーチェーン操作に失敗しました（{operation}: {message}）
  String keychain({required String operation, required String message}) =>
      _format(_table["host.failure.keychain"]!, {"operation": operation, "message": message});

  /// 接続に失敗しました
  String get peerFailed => _table["host.failure.peerFailed"]!;

  /// PeerConnection を生成できません
  String get peerUnavailable => _table["host.failure.peerUnavailable"]!;

  /// ビューアとの接続が切れました
  String get viewerDisconnected => _table["host.failure.viewerDisconnected"]!;

  /// ビューアが切断しました
  String get viewerLeft => _table["host.failure.viewerLeft"]!;

  /// ビューアページがバンドルに含まれていません（apps/web のビルドを確認してください）
  String get viewerPageMissing => _table["host.failure.viewerPageMissing"]!;
}

final class L10nMenu {
  const L10nMenu._();

  /// DoppelScreen について
  String get about => _table["host.menu.about"]!;

  /// エラー
  String get failed => _table["host.menu.failed"]!;

  /// DoppelScreen を終了
  String get quit => _table["host.menu.quit"]!;

  /// {count} 件の接続要求
  String requests({required String count}) =>
      _format(_table["host.menu.requests"]!, {"count": count});

  /// 待受中（{count} 画面を配信）
  String serving({required String count}) =>
      _format(_table["host.menu.serving"]!, {"count": count});

  /// ウィンドウを表示
  String get showWindow => _table["host.menu.showWindow"]!;

  /// 開始中…
  String get starting => _table["host.menu.starting"]!;

  /// 停止中
  String get stopped => _table["host.menu.stopped"]!;
}

final class L10nOnboarding {
  const L10nOnboarding._();

  /// 現在の状態: 未許可（1 秒ごとに再確認しています）
  String get checking => _table["host.onboarding.checking"]!;

  /// システム設定の「プライバシーとセキュリティ  ›  画面収録」で DoppelScreen を許可してください。
  String get guidanceAgain => _table["host.onboarding.guidanceAgain"]!;

  /// DoppelScreen はこの Mac の画面を配信します。
  String get guidanceFirst => _table["host.onboarding.guidanceFirst"]!;

  /// システム設定を開く
  String get openSettings => _table["host.onboarding.openSettings"]!;

  /// 再起動して反映
  String get relaunch => _table["host.onboarding.relaunch"]!;

  /// 許可を求める
  String get request => _table["host.onboarding.request"]!;

  /// 画面収録の許可が必要です
  String get title => _table["host.onboarding.title"]!;
}

final class L10nPairing {
  const L10nPairing._();

  /// 期限切れ。作り直してください
  String get expired => _table["host.pairing.expired"]!;

  /// あと {seconds} 秒で新しくなります
  String expires({required String seconds}) =>
      _format(_table["host.pairing.expires"]!, {"seconds": seconds});

  /// 作り直す
  String get regenerate => _table["host.pairing.regenerate"]!;

  /// トークンの誤りが続いたため作り直しました
  String get rejected => _table["host.pairing.rejected"]!;

  /// 接続トークン: {token}
  String token({required String token}) =>
      _format(_table["host.pairing.token"]!, {"token": token});
}

final class L10nQuality {
  const L10nQuality._();

  /// バランス
  String get balanced => _table["host.quality.balanced"]!;

  /// 文字くっきり
  String get sharp => _table["host.quality.sharp"]!;

  /// なめらか
  String get smooth => _table["host.quality.smooth"]!;
}

final class L10nStatus {
  const L10nStatus._();

  /// {count} 件の接続要求
  String requests({required String count}) =>
      _format(_table["host.status.requests"]!, {"count": count});

  /// {active} / {total} 画面を配信中
  String streaming({required String active, required String total}) =>
      _format(_table["host.status.streaming"]!, {"active": active, "total": total});
}
