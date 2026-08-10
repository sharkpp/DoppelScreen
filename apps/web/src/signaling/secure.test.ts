import { describe, expect, it } from "vitest";
import { secureURL } from "./secure";

describe("secureURL", () => {
  it("トークンを保ったまま HTTPS 側へ向ける", () => {
    expect(
      secureURL(
        { protocol: "http:", hostname: "192.168.1.10", hash: "#tok" },
        8423,
      ),
    ).toBe("https://192.168.1.10:8423/#tok");
  });

  it("既に HTTPS なら案内しない", () => {
    expect(
      secureURL({ protocol: "https:", hostname: "h", hash: "#tok" }, 8423),
    ).toBeNull();
  });

  it("HTTPS 側が立っていなければ案内しない", () => {
    expect(
      secureURL({ protocol: "http:", hostname: "h", hash: "#tok" }, null),
    ).toBeNull();
  });
});
