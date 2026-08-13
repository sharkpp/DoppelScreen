// 遅延計測（SPEC.md §3.3）。
//
// 「低遅延」は計測できなければ検証できない。M0 から用意する。
// `RTCStatsReport` の読み出しは純粋関数として切り出し、ブラウザなしでテストする。

export type StatsEntry = Record<string, unknown> & { type: string };

/**
 * 差分から求める値のための、前回の観測。
 *
 * `getStats()` が返すのはほぼすべて**接続してからの累積値**なので、そのまま割ると
 * 一生ぶんの平均になる。一度跳ねた値が下がってこない表示になり、いま何が起きているかを
 * 読めなくなる。すべて前回との差分で見る。
 */
export type Sample = {
  timestampMs: number;
  framesDecoded: number;
  bytesReceived: number;
  jitterBufferDelay: number;
  jitterBufferEmittedCount: number;
  totalDecodeTime: number;
  /** 区間にフレームが 1 枚も来なかったときに持ち越す、直前の読み */
  jitterBufferMs: number;
  decodeMs: number;
};

export type Latency = {
  fps: number;
  width: number;
  height: number;
  /** ジッタバッファの滞留。0 に近いほどよい（SPEC.md §3.2 の最大のレバー） */
  jitterBufferMs: number;
  decodeMs: number;
  rttMs: number;
  framesDropped: number;
  megabitsPerSecond: number;
};

export type Reading = { latency: Latency; sample: Sample };

function number(entry: StatsEntry | undefined, key: string): number {
  const value = entry?.[key];
  return typeof value === "number" ? value : 0;
}

export function summarize(entries: StatsEntry[], previous?: Sample): Reading {
  const inbound = entries.find(
    (entry) => entry.type === "inbound-rtp" && entry.kind === "video",
  );
  // 実際に使われている経路だけを見る。落選した候補の RTT は意味がない
  const pair = entries.find(
    (entry) =>
      entry.type === "candidate-pair" &&
      (entry.nominated === true || entry.state === "succeeded"),
  );

  const timestampMs = number(inbound, "timestamp");
  const framesDecoded = number(inbound, "framesDecoded");
  const bytesReceived = number(inbound, "bytesReceived");
  const elapsedSeconds = previous
    ? (timestampMs - previous.timestampMs) / 1000
    : 0;

  const jitterBufferDelay = number(inbound, "jitterBufferDelay");
  const emitted = number(inbound, "jitterBufferEmittedCount");
  const totalDecodeTime = number(inbound, "totalDecodeTime");

  // 区間に出たフレームだけで平均する。静止していてフレームが来ない区間（SPEC.md §4.3）は
  // 割る相手がいないので、直前の読みを持ち越す。0 を出すと「とても良い」に見えてしまう
  const emittedDelta = emitted - (previous?.jitterBufferEmittedCount ?? 0);
  const decodedDelta = framesDecoded - (previous?.framesDecoded ?? 0);

  const jitterBufferMs =
    emittedDelta > 0
      ? ((jitterBufferDelay - (previous?.jitterBufferDelay ?? 0)) /
          emittedDelta) *
        1000
      : (previous?.jitterBufferMs ?? 0);
  const decodeMs =
    decodedDelta > 0
      ? ((totalDecodeTime - (previous?.totalDecodeTime ?? 0)) / decodedDelta) *
        1000
      : (previous?.decodeMs ?? 0);

  return {
    latency: {
      fps: elapsedSeconds > 0 ? decodedDelta / elapsedSeconds : 0,
      width: number(inbound, "frameWidth"),
      height: number(inbound, "frameHeight"),
      jitterBufferMs,
      decodeMs,
      rttMs: number(pair, "currentRoundTripTime") * 1000,
      framesDropped: number(inbound, "framesDropped"),
      megabitsPerSecond:
        elapsedSeconds > 0
          ? ((bytesReceived - previous!.bytesReceived) * 8) /
            elapsedSeconds /
            1_000_000
          : 0,
    },
    sample: {
      timestampMs,
      framesDecoded,
      bytesReceived,
      jitterBufferDelay,
      jitterBufferEmittedCount: emitted,
      totalDecodeTime,
      jitterBufferMs,
      decodeMs,
    },
  };
}

export function format(latency: Latency): string {
  const round = (value: number, digits = 1) => value.toFixed(digits);
  return [
    `${latency.width}×${latency.height} ${round(latency.fps)}fps ${round(latency.megabitsPerSecond)}Mbps`,
    `jitter ${round(latency.jitterBufferMs)}ms  decode ${round(latency.decodeMs)}ms  rtt ${round(latency.rttMs)}ms  dropped ${latency.framesDropped}`,
  ].join("\n");
}
