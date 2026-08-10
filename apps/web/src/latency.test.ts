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

describe("summarize", () => {
  it("累積値を 1 フレームあたりに直す", () => {
    const { latency } = summarize([inbound, pair]);
    expect(latency.jitterBufferMs).toBeCloseTo(5);
    expect(latency.decodeMs).toBeCloseTo(4);
    expect(latency.rttMs).toBeCloseTo(4);
    expect(latency.width).toBe(1920);
    expect(latency.framesDropped).toBe(3);
  });

  it("前回の観測との差分から fps とビットレートを出す", () => {
    const { latency } = summarize([inbound, pair], {
      timestampMs: 1000,
      framesDecoded: 60,
      bytesReceived: 1_000_000,
    });
    expect(latency.fps).toBeCloseTo(60);
    expect(latency.megabitsPerSecond).toBeCloseTo(8);
  });

  it("初回は差分を取れないので 0 にする", () => {
    const { latency, sample } = summarize([inbound, pair]);
    expect(latency.fps).toBe(0);
    expect(sample).toEqual({
      timestampMs: 2000,
      framesDecoded: 120,
      bytesReceived: 2_000_000,
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
