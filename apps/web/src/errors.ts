// ホストから届くエラーコードを、**ビューアを見ている人の言語**に直す（SPEC.md §11-7）。
//
// ホストが文言を組み立てて送る形にしない。ホストの表示言語とビューアの表示言語は
// 一致しない（Mac は日本語、手元の iPad は英語、という組み合わせが普通にある）。
// ホストが送るのはコードだけで、`detail` は OS 由来の説明などコードにできない補足に限る。

import { t } from "./generated/strings";

/** 繋ぎ直しても直らないもの。自動再接続を止め、人に何をすべきか伝える */
const FATAL = new Set([
  "invalid_token",
  "token_expired",
  "too_many_attempts",
  "display_not_found",
  "rejected",
]);

export function isFatal(code: string): boolean {
  return FATAL.has(code);
}

export function describeError(code: string, detail?: string | null): string {
  switch (code) {
    case "invalid_token":
      return t.error.invalidToken;
    case "token_expired":
      return t.error.tokenExpired;
    case "too_many_attempts":
      return t.error.tooManyAttempts;
    case "display_not_found":
      return t.error.displayNotFound;
    case "rejected":
      return t.error.rejected;
    case "capture_stopped":
      return t.error.captureStopped;
    case "capture_failed":
      return t.error.captureFailed;
    case "host_closed":
      return t.error.hostClosed;
    case "connect_failed":
      return t.error.connectFailed;
    case "peer_failed":
      return t.error.peerFailed;
    default:
      // 知らないコードでも黙らない。ホストが補足を付けていればそれを出す
      return detail ?? t.error.unknown;
  }
}
