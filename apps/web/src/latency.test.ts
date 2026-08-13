import { describe, expect, it } from "vitest";
import { format, summarize, type StatsEntry } from "./latency";

const inbound: StatsEntry = {
  type: "inbound-rtp",
  kind: "video",
  timestamp: 2000,
  framesDecoded: 120,
  bytesReceived: 2_000_000,
  frameWidth: 1920,
  frameHeight: 1080,
  jitterBufferDelay: 0.6,
  jitterBufferEmittedCount: 120,
  totalDecodeTime: 0.48,
  framesDropped: 3,
};

const pair: StatsEntry = {
  type: "candidate-pair",
  nominated: true,
  currentRoundTripTime: 0.004,
};

/** 1 秒前の観測。ここから `inbound` までが 1 区間になる */
const earlier: StatsEntry = {
  ...inbound,
  timestamp: 1000,
  framesDecoded: 60,
  bytesReceived: 1_000_000,
  jitterBufferDelay: 0.54,
  jitterBufferEmittedCount: 60,
  totalDecodeTime: 0.36,
};

const before = summarize([earlier, pair]).sample;

describe("summarize", () => {
  it("初回は累積値を 1 フレームあたりに直す", () => {
    const { latency } = summarize([inbound, pair]);
    expect(latency.jitterBufferMs).toBeCloseTo(5);
    expect(latency.decodeMs).toBeCloseTo(4);
    expect(latency.rttMs).toBeCloseTo(4);
    expect(latency.width).toBe(1920);
    expect(latency.framesDropped).toBe(3);
  });

  it("前回の観測との差分から fps とビットレートを出す", () => {
    const { latency } = summarize([inbound, pair], before);
    expect(latency.fps).toBeCloseTo(60);
    expect(latency.megabitsPerSecond).toBeCloseTo(8);
  });

  // 累積値のまま割ると一生ぶんの平均になり、一度跳ねた値が下がってこない
  it("ジッタバッファと復号時間はその区間だけで平均する", () => {
    const { latency } = summarize([inbound, pair], before);
    // 区間の滞留は (0.6 - 0.54) / 60 フレーム = 1ms。累積平均の 5ms とは別物
    expect(latency.jitterBufferMs).toBeCloseTo(1);
    expect(latency.decodeMs).toBeCloseTo(2);
  });

  it("区間にフレームが来なければ直前の読みを持ち越す", () => {
    // 静止していて送出が止まっている間（SPEC.md §4.3）。0 を出すと「とても良い」に見える
    // 累積値が 1 つも進んでいない = この 1 秒に 1 枚も届いていない
    const still = summarize([{ ...earlier, timestamp: 3000 }, pair], before);
    expect(still.latency.jitterBufferMs).toBeCloseTo(before.jitterBufferMs);
    expect(still.latency.decodeMs).toBeCloseTo(before.decodeMs);
    expect(still.latency.fps).toBe(0);
  });

  it("初回は差分を取れないので fps は 0 にする", () => {
    const { latency, sample } = summarize([inbound, pair]);
    expect(latency.fps).toBe(0);
    expect(sample).toMatchObject({
      timestampMs: 2000,
      framesDecoded: 120,
      bytesReceived: 2_000_000,
      jitterBufferDelay: 0.6,
      jitterBufferEmittedCount: 120,
      totalDecodeTime: 0.48,
    });
  });

  it("落選した候補ペアの RTT は使わない", () => {
    const losing: StatsEntry = {
      type: "candidate-pair",
      state: "failed",
      currentRoundTripTime: 9,
    };
    expect(summarize([inbound, losing, pair]).latency.rttMs).toBeCloseTo(4);
  });

  it("統計が揃わなくても壊れない", () => {
    const { latency } = summarize([]);
    expect(latency.jitterBufferMs).toBe(0);
    expect(latency.decodeMs).toBe(0);
    expect(format(latency)).toContain("0.0fps");
  });
});
