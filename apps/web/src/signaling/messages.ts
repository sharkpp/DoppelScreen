// シグナリング（WebSocket `/signal`）で流すメッセージ。
// SPEC.md §7 の制御チャネル（DataChannel）とは別物で、こちらは接続確立にだけ使う。
//
// パースは純粋関数として切り出し、ブラウザなしでテストする（docs/STACK.md §6.3）。

export type IceCandidateMessage = {
  t: "candidate";
  candidate: string;
  sdpMid: string | null;
  sdpMLineIndex: number | null;
};

/** ホスト → ビューア */
export type HostMessage =
  | { t: "offer"; sdp: string }
  | IceCandidateMessage
  | { t: "error"; message: string };

/** ビューア → ホスト */
export type ViewerMessage =
  | { t: "hello"; token: string }
  | { t: "answer"; sdp: string }
  | IceCandidateMessage;

/**
 * ホストからのメッセージを解釈する。解釈できないものは `null` を返して黙って捨てる
 * （版の食い違いで未知のメッセージが来ても接続を落とさない）。
 */
export function parseHostMessage(raw: string): HostMessage | null {
  let value: unknown;
  try {
    value = JSON.parse(raw);
  } catch {
    return null;
  }
  if (typeof value !== "object" || value === null) return null;
  const message = value as Record<string, unknown>;

  switch (message.t) {
    case "offer":
      return typeof message.sdp === "string"
        ? { t: "offer", sdp: message.sdp }
        : null;
    case "candidate":
      return parseCandidate(message);
    case "error":
      return typeof message.message === "string"
        ? { t: "error", message: message.message }
        : null;
    default:
      return null;
  }
}

function parseCandidate(
  message: Record<string, unknown>,
): IceCandidateMessage | null {
  if (typeof message.candidate !== "string") return null;
  return {
    t: "candidate",
    candidate: message.candidate,
    sdpMid: typeof message.sdpMid === "string" ? message.sdpMid : null,
    sdpMLineIndex:
      typeof message.sdpMLineIndex === "number" ? message.sdpMLineIndex : null,
  };
}

export function encodeViewerMessage(message: ViewerMessage): string {
  return JSON.stringify(message);
}
