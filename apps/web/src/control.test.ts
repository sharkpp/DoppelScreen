import { describe, expect, it } from "vitest";
import {
  encodeViewerControl,
  measureViewport,
  parseHostControl,
} from "./control";

describe("parseHostControl", () => {
  it("hello を読む", () => {
    const raw =
      '{"t":"hello","platform":"macos","display":{"id":1,"name":"Built-in","w":2880,"h":1800,"scale":2}}';
    expect(parseHostControl(raw)).toEqual({
      t: "hello",
      platform: "macos",
      display: { id: 1, name: "Built-in", w: 2880, h: 1800, scale: 2 },
    });
  });

  it("display を読む", () => {
    const raw = '{"t":"display","id":2,"name":"U2720Q","w":3840,"h":2160}';
    expect(parseHostControl(raw)).toEqual({
      t: "display",
      id: 2,
      name: "U2720Q",
      w: 3840,
      h: 2160,
      scale: 1,
    });
  });

  it("stats を読む", () => {
    expect(
      parseHostControl('{"t":"stats","fps":59.4,"bitrate":21400000}'),
    ).toEqual({ t: "stats", fps: 59.4, bitrate: 21400000, encodeMs: 0 });
  });

  it("error を読む。文言ではなくコードで届く（SPEC.md §11-7）", () => {
    expect(
      parseHostControl('{"t":"error","code":"capture_stopped","detail":"止"}'),
    ).toEqual({ t: "error", code: "capture_stopped", detail: "止" });
  });

  it("error の detail は無くてよい", () => {
    expect(parseHostControl('{"t":"error","code":"rejected"}')).toEqual({
      t: "error",
      code: "rejected",
      detail: null,
    });
  });

  it("resume を読む（SPEC.md §11-4）", () => {
    expect(
      parseHostControl('{"t":"resume","ticket":"abc","ttlMs":600000}'),
    ).toEqual({ t: "resume", ticket: "abc", ttlMs: 600000 });
  });

  it("未知の種別・壊れた JSON・型違いは null を返して捨てる", () => {
    // quality はビューア → ホストの向き。ホストからは来ない
    expect(parseHostControl('{"t":"quality","preset":"sharp"}')).toBeNull();
    expect(parseHostControl('{"t":"error"}')).toBeNull();
    expect(parseHostControl('{"t":"resume","ticket":"abc"}')).toBeNull();
    expect(parseHostControl("{")).toBeNull();
    expect(parseHostControl("null")).toBeNull();
    expect(parseHostControl('{"t":"hello","platform":"macos"}')).toBeNull();
    expect(parseHostControl('{"t":"display","id":"1"}')).toBeNull();
    expect(parseHostControl('{"t":"stats"}')).toBeNull();
  });
});

describe("measureViewport", () => {
  it("物理ピクセルで申告する（CSS ピクセルだと実解像度の半分しか受け取れない）", () => {
    expect(
      measureViewport({
        innerWidth: 1024,
        innerHeight: 768,
        devicePixelRatio: 2,
      }),
    ).toEqual({ t: "viewport", w: 2048, h: 1536, dpr: 2 });
  });

  it("devicePixelRatio を持たない環境では等倍として扱う", () => {
    expect(
      measureViewport({
        innerWidth: 1280,
        innerHeight: 720,
        devicePixelRatio: 0,
      }),
    ).toEqual({ t: "viewport", w: 1280, h: 720, dpr: 1 });
  });
});

describe("encodeViewerControl", () => {
  it("viewport を書く", () => {
    expect(
      encodeViewerControl({ t: "viewport", w: 2048, h: 1536, dpr: 2 }),
    ).toBe('{"t":"viewport","w":2048,"h":1536,"dpr":2}');
  });

  it("quality を書く（SPEC.md §7.2）", () => {
    expect(encodeViewerControl({ t: "quality", preset: "smooth" })).toBe(
      '{"t":"quality","preset":"smooth"}',
    );
  });
});
