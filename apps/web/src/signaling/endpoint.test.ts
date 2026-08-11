import { describe, expect, it } from "vitest";
import { resolveEndpoint } from "./endpoint";

describe("resolveEndpoint", () => {
  it("HTTP なら ws:", () => {
    expect(
      resolveEndpoint({
        protocol: "http:",
        host: "192.168.1.10:8422",
        hash: "#tok",
        search: "",
      }),
    ).toEqual({
      signalUrl: "ws://192.168.1.10:8422/signal",
      token: "tok",
      display: null,
    });
  });

  it("HTTPS なら wss:（混在コンテンツでブロックされるため必ず導出する）", () => {
    expect(
      resolveEndpoint({
        protocol: "https:",
        host: "192.168.1.10:8423",
        hash: "#tok",
        search: "",
      }),
    ).toEqual({
      signalUrl: "wss://192.168.1.10:8423/signal",
      token: "tok",
      display: null,
    });
  });

  it("開発時は ?host= で実ホストへ向ける", () => {
    expect(
      resolveEndpoint({
        protocol: "http:",
        host: "localhost:5173",
        hash: "#tok",
        search: "?host=192.168.1.10:8422",
      }),
    ).toEqual({
      signalUrl: "ws://192.168.1.10:8422/signal",
      token: "tok",
      display: null,
    });
  });

  it("?d= で映す画面を指す（画面ごとに URL が分かれる）", () => {
    expect(
      resolveEndpoint({
        protocol: "http:",
        host: "h",
        hash: "#tok",
        search: "?d=7",
      }).display,
    ).toBe(7);
  });

  it("画面の指定が無い・数でない・0 なら null（ホストが主画面を選ぶ）", () => {
    const at = (search: string) =>
      resolveEndpoint({ protocol: "http:", host: "h", hash: "#t", search })
        .display;
    expect(at("")).toBeNull();
    expect(at("?d=abc")).toBeNull();
    expect(at("?d=0")).toBeNull();
    expect(at("?d=1.5")).toBeNull();
  });

  it("fragment がなければトークンは空", () => {
    expect(
      resolveEndpoint({ protocol: "http:", host: "h", hash: "", search: "" })
        .token,
    ).toBe("");
  });
});
