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
    ).toEqual({ signalUrl: "ws://192.168.1.10:8422/signal", token: "tok" });
  });

  it("HTTPS なら wss:（混在コンテンツでブロックされるため必ず導出する）", () => {
    expect(
      resolveEndpoint({
        protocol: "https:",
        host: "192.168.1.10:8423",
        hash: "#tok",
        search: "",
      }),
    ).toEqual({ signalUrl: "wss://192.168.1.10:8423/signal", token: "tok" });
  });

  it("開発時は ?host= で実ホストへ向ける", () => {
    expect(
      resolveEndpoint({
        protocol: "http:",
        host: "localhost:5173",
        hash: "#tok",
        search: "?host=192.168.1.10:8422",
      }),
    ).toEqual({ signalUrl: "ws://192.168.1.10:8422/signal", token: "tok" });
  });

  it("fragment がなければトークンは空", () => {
    expect(
      resolveEndpoint({ protocol: "http:", host: "h", hash: "", search: "" })
        .token,
    ).toBe("");
  });
});
