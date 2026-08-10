import { expect, test } from "@playwright/test";
import { Host } from "./host";

/**
 * M0 の完了条件（SPEC.md §10）の機械的な確認。
 * ホストの画面がブラウザに映るところまでを、UI 操作なしで通しで見る。
 */
test("ホストの画面がブラウザに映る", async ({ page }) => {
  const host = new Host();
  const handshake = await host.start(60);

  try {
    // 同一マシンから繋ぐのでループバックを使う。LAN アドレスでも通るが、
    // macOS 15 のローカルネットワーク許諾を巻き込まない分こちらが安定する
    const url = `http://127.0.0.1:${handshake.port}/#${handshake.token}`;
    await page.goto(url);

    const video = page.locator("#screen");
    await expect(video).toBeVisible();

    // 映像が来ていることの判定。解像度が付き、再生位置が進んでいること
    await expect
      .poll(
        () => video.evaluate((element: HTMLVideoElement) => element.videoWidth),
        { message: "映像トラックが届きません", timeout: 30_000 },
      )
      .toBeGreaterThan(0);

    await expect
      .poll(
        () =>
          video.evaluate(
            (element: HTMLVideoElement) =>
              element.currentTime > 0 && !element.paused,
          ),
        { message: "映像が再生されません" },
      )
      .toBe(true);

    // 受信側の実測。デコードまで通っていることを確認する
    const decoded = await page.evaluate(async () => {
      const target = document.querySelector("video") as HTMLVideoElement;
      return { width: target.videoWidth, height: target.videoHeight };
    });
    expect(decoded.width).toBeGreaterThan(0);

    // ホスト側の言い分と突き合わせる
    const report = await host.report(60_000);
    expect(report.serve?.viewerConnected, report.error).toBe(true);
    expect(report.serve?.framesSent).toBeGreaterThan(0);
    expect(report.serve?.codec).toContain("H264");
    expect(report.ok, report.error).toBe(true);
  } finally {
    await host.cleanup();
  }
});

test("トークンが違うと接続できない", async ({ page }) => {
  const host = new Host();
  const handshake = await host.start(15);

  try {
    await page.goto(`http://127.0.0.1:${handshake.port}/#wrongtoken`);
    await expect(page.locator("#status")).toContainText("トークン");

    const report = await host.report(60_000);
    expect(report.serve?.viewerConnected).toBe(false);
  } finally {
    await host.cleanup();
  }
});
