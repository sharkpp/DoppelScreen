// 自動生成 — 直接編集しない。i18n/*.yaml を直して `make i18n` を実行する。

export type Language = "ja" | "en";

const BASE: Language = "ja";

// キーを有限のユニオンで持つ。綴りを間違えた参照はコンパイルで落ちる
type Key =
  | "viewer.controls.exitFullscreen"
  | "viewer.controls.fullscreen"
  | "viewer.controls.stats"
  | "viewer.error.captureFailed"
  | "viewer.error.captureStopped"
  | "viewer.error.connectFailed"
  | "viewer.error.displayNotFound"
  | "viewer.error.hostClosed"
  | "viewer.error.invalidToken"
  | "viewer.error.peerFailed"
  | "viewer.error.rejected"
  | "viewer.error.tokenExpired"
  | "viewer.error.tooManyAttempts"
  | "viewer.error.unknown"
  | "viewer.quality.balanced"
  | "viewer.quality.changed"
  | "viewer.quality.sharp"
  | "viewer.quality.smooth"
  | "viewer.secure.open"
  | "viewer.secure.required"
  | "viewer.secure.unreachable"
  | "viewer.status.awaitingApproval"
  | "viewer.status.connected"
  | "viewer.status.connectedTo"
  | "viewer.status.connecting"
  | "viewer.status.negotiating"
  | "viewer.status.reconnecting"
  | "viewer.status.retry"
  | "viewer.status.tapToPlay";

const messages: Record<Language, Record<Key, string>> = {
  "ja": {
    "viewer.controls.exitFullscreen": "全画面を終了",
    "viewer.controls.fullscreen": "全画面",
    "viewer.controls.stats": "遅延",
    "viewer.error.captureFailed": "ホスト側で画面の取得を開始できませんでした",
    "viewer.error.captureStopped": "ホスト側で画面の取得が止まりました",
    "viewer.error.connectFailed": "ホストへ接続できませんでした",
    "viewer.error.displayNotFound": "指定された画面が見つかりません",
    "viewer.error.hostClosed": "ホストとの接続が切れました",
    "viewer.error.invalidToken": "接続トークンが正しくありません。QR を読み直してください",
    "viewer.error.peerFailed": "接続に失敗しました",
    "viewer.error.rejected": "ホストが接続を承認しませんでした",
    "viewer.error.tokenExpired": "接続トークンの期限が切れました。ホストの QR を読み直してください",
    "viewer.error.tooManyAttempts": "接続の試行が多すぎます。ホストで QR を出し直してください",
    "viewer.error.unknown": "エラーが発生しました",
    "viewer.quality.balanced": "バランス",
    "viewer.quality.changed": "画質: {preset}",
    "viewer.quality.sharp": "文字くっきり",
    "viewer.quality.smooth": "なめらか",
    "viewer.secure.open": "HTTPS で開き直す",
    "viewer.secure.required": "このブラウザは WebRTC にセキュアな接続を必要とします。",
    "viewer.secure.unreachable": "接続できません。",
    "viewer.status.awaitingApproval": "ホストでの承認を待っています…",
    "viewer.status.connected": "接続しました",
    "viewer.status.connectedTo": "{display} に接続",
    "viewer.status.connecting": "ホストへ接続しています…",
    "viewer.status.negotiating": "映像を準備しています…",
    "viewer.status.reconnecting": "接続が切れました。再接続しています…",
    "viewer.status.retry": "再接続する",
    "viewer.status.tapToPlay": "画面をタップして再生してください",
  },
  "en": {
    "viewer.controls.exitFullscreen": "Exit full screen",
    "viewer.controls.fullscreen": "Full screen",
    "viewer.controls.stats": "Latency",
    "viewer.error.captureFailed": "The host could not start capturing the screen",
    "viewer.error.captureStopped": "Screen capture stopped on the host",
    "viewer.error.connectFailed": "Could not reach the host",
    "viewer.error.displayNotFound": "The requested display was not found",
    "viewer.error.hostClosed": "The connection to the host was lost",
    "viewer.error.invalidToken": "The pairing token is not valid. Scan the QR again",
    "viewer.error.peerFailed": "The connection failed",
    "viewer.error.rejected": "The host did not approve the connection",
    "viewer.error.tokenExpired": "The pairing token has expired. Scan the host's QR again",
    "viewer.error.tooManyAttempts": "Too many attempts. Have the host show a new QR",
    "viewer.error.unknown": "An error occurred",
    "viewer.quality.balanced": "Balanced",
    "viewer.quality.changed": "Quality: {preset}",
    "viewer.quality.sharp": "Sharp text",
    "viewer.quality.smooth": "Smooth",
    "viewer.secure.open": "Reopen over HTTPS",
    "viewer.secure.required": "This browser requires a secure connection for WebRTC.",
    "viewer.secure.unreachable": "Cannot reach the host.",
    "viewer.status.awaitingApproval": "Waiting for approval on the host…",
    "viewer.status.connected": "Connected",
    "viewer.status.connectedTo": "Connected to {display}",
    "viewer.status.connecting": "Connecting to the host…",
    "viewer.status.negotiating": "Preparing video…",
    "viewer.status.reconnecting": "Connection lost. Reconnecting…",
    "viewer.status.retry": "Reconnect",
    "viewer.status.tapToPlay": "Tap the screen to start playback",
  },
};

/**
 * ブラウザの表示言語から 1 つ選ぶ。地域まで一致しなくてよい（`en-GB` は `en` として扱う）。
 * どれとも合わなければ基準言語へ落とす。
 */
export function resolveLanguage(preferred: readonly string[]): Language {
  for (const tag of preferred) {
    const primary = tag.toLowerCase().split("-")[0];
    const match = (Object.keys(messages) as Language[]).find((language) => language === primary);
    if (match) return match;
  }
  return BASE;
}

export const language: Language = resolveLanguage(
  typeof navigator === "undefined" ? [] : (navigator.languages ?? [navigator.language]),
);

const table = messages[language];

function format(text: string, values: Record<string, string>): string {
  return text.replace(
    /\{([A-Za-z][A-Za-z0-9]*)\}/g,
    (whole, name: string) => values[name] ?? whole,
  );
}

/** 文言。プレースホルダを持つものだけ関数になる */
export const t = {
  controls: {
    /** 全画面を終了 */
    exitFullscreen: table["viewer.controls.exitFullscreen"],
    /** 全画面 */
    fullscreen: table["viewer.controls.fullscreen"],
    /** 遅延 */
    stats: table["viewer.controls.stats"],
  },
  error: {
    /** ホスト側で画面の取得を開始できませんでした */
    captureFailed: table["viewer.error.captureFailed"],
    /** ホスト側で画面の取得が止まりました */
    captureStopped: table["viewer.error.captureStopped"],
    /** ホストへ接続できませんでした */
    connectFailed: table["viewer.error.connectFailed"],
    /** 指定された画面が見つかりません */
    displayNotFound: table["viewer.error.displayNotFound"],
    /** ホストとの接続が切れました */
    hostClosed: table["viewer.error.hostClosed"],
    /** 接続トークンが正しくありません。QR を読み直してください */
    invalidToken: table["viewer.error.invalidToken"],
    /** 接続に失敗しました */
    peerFailed: table["viewer.error.peerFailed"],
    /** ホストが接続を承認しませんでした */
    rejected: table["viewer.error.rejected"],
    /** 接続トークンの期限が切れました。ホストの QR を読み直してください */
    tokenExpired: table["viewer.error.tokenExpired"],
    /** 接続の試行が多すぎます。ホストで QR を出し直してください */
    tooManyAttempts: table["viewer.error.tooManyAttempts"],
    /** エラーが発生しました */
    unknown: table["viewer.error.unknown"],
  },
  quality: {
    /** バランス */
    balanced: table["viewer.quality.balanced"],
    /** 画質: {preset} */
    changed: (values: { preset: string }) => format(table["viewer.quality.changed"], values),
    /** 文字くっきり */
    sharp: table["viewer.quality.sharp"],
    /** なめらか */
    smooth: table["viewer.quality.smooth"],
  },
  secure: {
    /** HTTPS で開き直す */
    open: table["viewer.secure.open"],
    /** このブラウザは WebRTC にセキュアな接続を必要とします。 */
    required: table["viewer.secure.required"],
    /** 接続できません。 */
    unreachable: table["viewer.secure.unreachable"],
  },
  status: {
    /** ホストでの承認を待っています… */
    awaitingApproval: table["viewer.status.awaitingApproval"],
    /** 接続しました */
    connected: table["viewer.status.connected"],
    /** {display} に接続 */
    connectedTo: (values: { display: string }) => format(table["viewer.status.connectedTo"], values),
    /** ホストへ接続しています… */
    connecting: table["viewer.status.connecting"],
    /** 映像を準備しています… */
    negotiating: table["viewer.status.negotiating"],
    /** 接続が切れました。再接続しています… */
    reconnecting: table["viewer.status.reconnecting"],
    /** 再接続する */
    retry: table["viewer.status.retry"],
    /** 画面をタップして再生してください */
    tapToPlay: table["viewer.status.tapToPlay"],
  },
};
