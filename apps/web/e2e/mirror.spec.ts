import { writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { expect, test } from "@playwright/test";
import { Host } from "./host";
import { summarize, type StatsEntry } from "../src/latency";

/** 実測値の置き場。リリースごとに同条件で見比べる（SPEC.md §3.3） */
const MEASUREMENT = resolve(
  import.meta.dirname,
  "../../macos/build/selftest/latency.json",
);

/**
 * M0 の完了条件（SPEC.md §10）の機械的な確認。
 * ホストの画面がブラウザに映るところまでを、UI 操作なしで通しで見る。
 */
test("ホストの画面がブラウザに映る", async ({ page }) => {
  const host = new Host();
  const handshake = await host.start(15);

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
    // ソフトウェアへ落ちていないこと。落ちると H.264 のつもりで VP8 が流れる
    // （apps/macos/Sources/Video/VideoEncoderFactory.swift）
    expect(report.serve?.encoderImplementation).toBe("VideoToolbox");
    // 立ち上がりの帯域推定で解像度が落ちていないこと（SPEC.md §3.2）
    expect(report.serve?.frameWidth).toBe(report.serve?.capturedWidth);
    expect(report.serve?.frameHeight).toBe(report.serve?.capturedHeight);
    expect(report.ok, report.error).toBe(true);
  } finally {
    await host.cleanup();
  }
});

/**
 * M1 の遅延（SPEC.md §3.1 のバジェット）を両側から実測し、記録に残す。
 *
 * glass-to-glass の実測はカメラが要る（docs/STACK.md §2.11）。ここで押さえるのは
 * ジッタバッファ・デコード・エンコードといった**内訳**で、リグレッションはこちらで検出する。
 */
test("遅延の内訳を実測して記録する", async ({ page }) => {
  const host = new Host();
  const handshake = await host.start(15);

  try {
    // ビューアが作る PeerConnection を捕まえる。`jitterBufferTarget` の実効値は
    // 統計に出ないため、レシーバ本体から読む（SPEC.md §3.2 の最大のレバー）
    await page.addInitScript(() => {
      const original = window.RTCPeerConnection;
      const captured: RTCPeerConnection[] = [];
      (window as unknown as { __peers: RTCPeerConnection[] }).__peers =
        captured;
      window.RTCPeerConnection = new Proxy(original, {
        construct(target, args: [RTCConfiguration?]) {
          const peer = new target(...args);
          captured.push(peer);
          return peer;
        },
      });
    });

    await page.goto(`http://127.0.0.1:${handshake.port}/#${handshake.token}`);
    await expect
      .poll(
        () =>
          page
            .locator("#screen")
            .evaluate((element: HTMLVideoElement) => element.videoWidth),
        { message: "映像トラックが届きません", timeout: 30_000 },
      )
      .toBeGreaterThan(0);

    // 立ち上がりの値は当てにならない。少し流してから 1 秒差で 2 回読む
    await page.waitForTimeout(4000);
    const viewer = await page.evaluate(async () => {
      const peers = (window as unknown as { __peers: RTCPeerConnection[] })
        .__peers;
      const peer = peers[peers.length - 1]!;
      const read = async () => {
        const entries: Record<string, unknown>[] = [];
        (await peer.getStats()).forEach((entry) => entries.push(entry));
        return entries;
      };
      const first = await read();
      await new Promise((done) => setTimeout(done, 1000));
      const receiver = peer.getReceivers()[0] as RTCRtpReceiver & {
        jitterBufferTarget?: number;
      };
      return {
        first,
        second: await read(),
        jitterBufferTarget: receiver?.jitterBufferTarget ?? null,
      };
    });

    const reading = summarize(
      viewer.second as StatsEntry[],
      summarize(viewer.first as StatsEntry[]).sample,
    );
    const report = await host.report(60_000);
    await writeFile(
      MEASUREMENT,
      JSON.stringify({ viewer: reading.latency, host: report.serve }, null, 1),
    );
    console.log("viewer:", reading.latency);
    console.log("host:", {
      encodeMs: report.serve?.encodeMs,
      packetSendMs: report.serve?.packetSendMs,
      keyFramesEncoded: report.serve?.keyFramesEncoded,
      targetBitrateMbps: report.serve?.targetBitrateMbps,
      qualityLimitationReason: report.serve?.qualityLimitationReason,
    });

    // 受信側が本当に読めていること（読めていなければ以下の判定に意味がない）
    expect(reading.latency.width).toBeGreaterThan(0);
    // ジッタバッファを捨てられていること。既定のままだと 100ms 級になりうる
    expect(viewer.jitterBufferTarget).toBe(0);
    expect(reading.latency.jitterBufferMs).toBeLessThan(50);
    expect(reading.latency.decodeMs).toBeLessThan(20);
    // 長 GOP。定期挿入があると数秒ごとにキーフレームが増える（SPEC.md §3.2）
    expect(report.serve?.keyFramesEncoded).toBeLessThanOrEqual(2);
  } finally {
    await host.cleanup();
  }
});

// 自己署名証明書なので警告を通す。ビューア端末では初回 1 回だけ人が通す（SPEC.md §5.3）
test.describe("HTTPS 経路", () => {
  test.use({ ignoreHTTPSErrors: true });

  test("HTTPS でも映る", async ({ page }) => {
    const host = new Host();
    const handshake = await host.start(15);

    try {
      expect(handshake.securePort, "HTTPS の待受が立っていません").toBeTruthy();
      await page.goto(
        `https://127.0.0.1:${handshake.securePort}/#${handshake.token}`,
      );

      await expect
        .poll(
          () =>
            page
              .locator("#screen")
              .evaluate((element: HTMLVideoElement) => element.videoWidth),
          { message: "映像トラックが届きません", timeout: 30_000 },
        )
        .toBeGreaterThan(0);

      const report = await host.report(60_000);
      expect(report.ok, report.error).toBe(true);
    } finally {
      await host.cleanup();
    }
  });
});

test("トークンが違うと接続できない", async ({ page }) => {
  const host = new Host();
  const handshake = await host.start(8);

  try {
    await page.goto(`http://127.0.0.1:${handshake.port}/#wrongtoken`);
    await expect(page.locator("#status")).toContainText("トークン");

    const report = await host.report(60_000);
    expect(report.serve?.viewerConnected).toBe(false);
  } finally {
    await host.cleanup();
  }
});
