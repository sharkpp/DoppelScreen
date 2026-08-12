import { defineConfig } from "@playwright/test";

// E2E はホストアプリを実際に起動して繋ぐ（docs/STACK.md §6.3）。
//
// **`channel: "chrome"` を使う。Playwright 同梱の Chromium ではだめ。**
// 同梱ビルドはプロプライエタリコーデックを含まず H.264 をデコードできないため、
// 接続はできても映像が出ない（本製品は H.264 固定 — SPEC.md §2.5）。
export default defineConfig({
  testDir: "./e2e",
  // ホストの起動・キャプチャ・接続待ちが入るため長めに取る
  timeout: 120_000,
  expect: { timeout: 30_000 },
  workers: 1,
  reporter: [["list"]],
  use: {
    channel: "chrome",
    // ビューアの文言は表示言語で切り替わる（SPEC.md §11-7）。
    // 判定を実行環境の言語設定に左右させないため固定する
    locale: "ja-JP",
    launchOptions: {
      args: [
        // 自動再生を人の操作なしに通す
        "--autoplay-policy=no-user-gesture-required",
      ],
    },
  },
});
