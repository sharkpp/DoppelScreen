import { describe, expect, it } from "vitest";
import { secureURL } from "./secure";

describe("secureURL", () => {
  it("トークンを保ったまま HTTPS 側へ向ける", () => {
    expect(
      secureURL(
        {
          protocol: "http:",
          hostname: "192.168.1.10",
          search: "",
          hash: "#tok",
        },
        8423,
      ),
    ).toBe("https://192.168.1.10:8423/#tok");
  });

  // 落とすと、切り替えた先で別の画面が映る（SPEC.md §5.2）
  it("画面の指定（?d=）も引き継ぐ", () => {
    expect(
      secureURL(
        {
          protocol: "http:",
          hostname: "192.168.1.10",
          search: "?d=7",
          hash: "#tok",
        },
        8423,
      ),
    ).toBe("https://192.168.1.10:8423/?d=7#tok");
  });

  it("既に HTTPS なら案内しない", () => {
    expect(
      secureURL(
        { protocol: "https:", hostname: "h", search: "", hash: "#tok" },
        8423,
      ),
    ).toBeNull();
  });

  it("HTTPS 側が立っていなければ案内しない", () => {
    expect(
      secureURL(
        { protocol: "http:", hostname: "h", search: "", hash: "#tok" },
        null,
      ),
    ).toBeNull();
  });
});
