// 遅延計測（SPEC.md §3.3）。
//
// 「低遅延」は計測できなければ検証できない。M0 から用意する。
// `RTCStatsReport` の読み出しは純粋関数として切り出し、ブラウザなしでテストする。

export type StatsEntry = Record<string, unknown> & { type: string };

/** 差分から求める値のための、前回の観測 */
export type Sample = {
  timestampMs: number;
  framesDecoded: number;
  bytesReceived: number;
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

  const emitted = number(inbound, "jitterBufferEmittedCount");

  return {
    latency: {
      fps:
        elapsedSeconds > 0
          ? (framesDecoded - previous!.framesDecoded) / elapsedSeconds
          : 0,
      width: number(inbound, "frameWidth"),
      height: number(inbound, "frameHeight"),
      // 累積値どうしの比。1 フレームあたりの滞留時間になる
      jitterBufferMs:
        emitted > 0
          ? (number(inbound, "jitterBufferDelay") / emitted) * 1000
          : 0,
      decodeMs:
        framesDecoded > 0
          ? (number(inbound, "totalDecodeTime") / framesDecoded) * 1000
          : 0,
      rttMs: number(pair, "currentRoundTripTime") * 1000,
      framesDropped: number(inbound, "framesDropped"),
      megabitsPerSecond:
        elapsedSeconds > 0
          ? ((bytesReceived - previous!.bytesReceived) * 8) /
            elapsedSeconds /
            1_000_000
          : 0,
    },
    sample: { timestampMs, framesDecoded, bytesReceived },
  };
}

export function format(latency: Latency): string {
  const round = (value: number, digits = 1) => value.toFixed(digits);
  return [
    `${latency.width}×${latency.height} ${round(latency.fps)}fps ${round(latency.megabitsPerSecond)}Mbps`,
    `jitter ${round(latency.jitterBufferMs)}ms  decode ${round(latency.decodeMs)}ms  rtt ${round(latency.rttMs)}ms  dropped ${latency.framesDropped}`,
  ].join("\n");
}
