import { describe, expect, it } from "vitest";
import { encodeViewerMessage, parseHostMessage } from "./messages";

describe("parseHostMessage", () => {
  it("offer を読む", () => {
    expect(parseHostMessage('{"t":"offer","sdp":"v=0"}')).toEqual({
      t: "offer",
      sdp: "v=0",
    });
  });

  it("candidate を読む", () => {
    const raw =
      '{"t":"candidate","candidate":"candidate:1 1 udp","sdpMid":"0","sdpMLineIndex":0}';
    expect(parseHostMessage(raw)).toEqual({
      t: "candidate",
      candidate: "candidate:1 1 udp",
      sdpMid: "0",
      sdpMLineIndex: 0,
    });
  });

  it("candidate の省略された属性は null になる", () => {
    expect(parseHostMessage('{"t":"candidate","candidate":"x"}')).toEqual({
      t: "candidate",
      candidate: "x",
      sdpMid: null,
      sdpMLineIndex: null,
    });
  });

  it("未知の種別・壊れた JSON・型違いは null を返して捨てる", () => {
    expect(parseHostMessage('{"t":"unknown"}')).toBeNull();
    expect(parseHostMessage("{")).toBeNull();
    expect(parseHostMessage("null")).toBeNull();
    expect(parseHostMessage('{"t":"offer","sdp":42}')).toBeNull();
    expect(parseHostMessage('{"t":"error"}')).toBeNull();
  });
});

describe("encodeViewerMessage", () => {
  it("hello を書く", () => {
    expect(encodeViewerMessage({ t: "hello", token: "abc" })).toBe(
      '{"t":"hello","token":"abc"}',
    );
  });
});
