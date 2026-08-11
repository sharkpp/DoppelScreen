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
    await page.goto(Host.viewerURL(handshake));

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
    // URL が指した画面が配信されていること（SPEC.md §5.2）
    expect(report.serve?.displayID).toBe(handshake.displayID);
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

    await page.goto(Host.viewerURL(handshake));
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
      await page.goto(Host.viewerURL(handshake, { secure: true }));

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

/**
 * M2 の解像度追従（SPEC.md §7.1）。遅延の支配要因はエンコードで、その支配要因は解像度
 * （docs/STACK.md §2.11）。ここが効かないと 60ms 目標に届かない。
 *
 * 判定はビューア側の `videoHeight` で行う。ホストの申告ではなく、**実際に復号された
 * 映像の解像度が変わったこと**を見る。
 */
test("ビューアの表示サイズに解像度が追従する", async ({ page }) => {
  const host = new Host();
  const handshake = await host.start(25);

  try {
    test.skip(
      handshake.displayHeight <= 1440,
      `ディスプレイが ${handshake.displayHeight}px しかなく、段階の差が出ません`,
    );

    const video = page.locator("#screen");
    const height = () =>
      video.evaluate((element: HTMLVideoElement) => element.videoHeight);

    await page.setViewportSize({ width: 1280, height: 720 });
    await page.goto(Host.viewerURL(handshake));

    // 720p の表示先には 720p を送る。実解像度をそのまま送ると
    // エンコード時間（＝遅延）と帯域を捨てるだけになる
    await expect
      .poll(height, { message: "720p へ落ちません", timeout: 30_000 })
      .toBe(720);

    // 広げたら追いつく。丸めは段階的（720p / 1080p / 1440p / 2160p）
    await page.setViewportSize({ width: 2560, height: 1440 });
    await expect
      .poll(height, { message: "1440p へ上がりません", timeout: 30_000 })
      .toBe(1440);

    const report = await host.report(60_000);
    expect(report.serve?.capturedHeight).toBe(1440);
    expect(report.serve?.frameHeight).toBe(1440);
  } finally {
    await host.cleanup();
  }
});

/**
 * 画面ごとに URL を分ける（SPEC.md §5.2）。別々の端末で別々の画面を同時に見られること。
 * ここが成り立たないと「画面ごとに配信する」という決定が実現できていない。
 */
test("2 つの画面を同時に別のビューアへ配信する", async ({ browser }) => {
  const host = new Host();
  const handshake = await host.start(25);

  try {
    test.skip(
      handshake.displayIDs.length < 2,
      "ディスプレイが 1 台しかありません",
    );
    const first = handshake.displayIDs[0]!;
    const second = handshake.displayIDs[1]!;

    // 端末を分けることに意味があるので、コンテキストごと分ける
    const pages = await Promise.all(
      [first, second].map(async (display) => {
        const page = await browser.newPage();
        await page.goto(Host.viewerURL(handshake, { display }));
        return page;
      }),
    );

    for (const [index, page] of pages.entries()) {
      await expect
        .poll(
          () =>
            page
              .locator("#screen")
              .evaluate((element: HTMLVideoElement) => element.videoWidth),
          { message: `${index + 1} 台目に映像が届きません`, timeout: 30_000 },
        )
        .toBeGreaterThan(0);
    }

    // それぞれのビューアが、自分が指した画面の名前を受け取っていること
    // （制御チャネルの `hello` — SPEC.md §7）。映像が出ているだけでは
    // 「2 台とも同じ画面を見ている」可能性を潰せない
    for (const page of pages) {
      await expect(page.locator("#status")).toContainText("に接続");
    }
    const labels = await Promise.all(
      pages.map((page) => page.locator("#status").textContent()),
    );
    for (const page of pages) await page.close();

    const report = await host.report(60_000);
    const nameOf = (id: number) =>
      report.displays?.find((display) => display.id === id)?.name;
    expect(labels[0]).toContain(nameOf(first));
    expect(labels[1]).toContain(nameOf(second));
  } finally {
    await host.cleanup();
  }
});

test("トークンが違うと接続できない", async ({ page }) => {
  const host = new Host();
  const handshake = await host.start(8);

  try {
    await page.goto(Host.viewerURL(handshake, { token: "wrongtoken" }));
    await expect(page.locator("#status")).toContainText("トークン");

    const report = await host.report(60_000);
    expect(report.serve?.viewerConnected).toBe(false);
  } finally {
    await host.cleanup();
  }
});
