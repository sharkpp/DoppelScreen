import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { expect, test, type Page } from "@playwright/test";
// @ts-expect-error 実行用のスクリプトなので型定義を持たない。純粋関数だけを借りる
import { latencyBetween, latencyOf } from "../latency/analyze.mjs";

/**
 * 計測ツール（`latency/clock.html` + `latency/analyze.mjs`）そのものの検証。
 *
 * **既知の遅延を埋め込んだ動画を合成し、解析がその値を言い当てるかを見る。**
 * カウンタは `?t=` で任意の時刻に静止できるので、ホスト側とビューア側を
 * 別々の時刻で描いて横に並べれば、遅延 D の撮影を人手なしで再現できる。
 *
 * ここで確かめられないのは、カメラ由来のもの（ブレ・ローリングシャッター・
 * ピント・反射）だけ。それ以外の経路 — QR の生成、H.264 を経た劣化、複数 QR の
 * 検出、どちらがホストかの判定、巡回のまたぎ、統計 — は全部通る。
 */

const CLOCK = resolve(import.meta.dirname, "../latency/dist/clock.html");
const ANALYZE = resolve(import.meta.dirname, "../latency/analyze.mjs");
const WEB = resolve(import.meta.dirname, "..");

/** カウンタの周期（latency/payload.ts の CYCLE_MS） */
const CYCLE = 1_000_000;
/** 60Hz の 1 フレーム */
const STEP = 1000 / 60;
const PANEL = { width: 700, height: 560 };

test.beforeAll(() => {
  // 単一 HTML なので、無ければ作る。テストのために手順を増やさない
  execFileSync("npm", ["run", "build:latency"], { cwd: WEB, stdio: "pipe" });
});

/**
 * 遅延 `delayMs` の撮影を合成する。ホスト側とビューア側を 2 つの iframe に
 * 別々の時刻で描き、1 枚に収めて H.264 で繋ぐ。
 */
async function synthesise(
  page: Page,
  directory: string,
  options: { delayMs: number; frames: number; startMs: number },
): Promise<string> {
  const clock = pathToFileURL(CLOCK).href;
  const harness = join(directory, "harness.html");

  await page.setViewportSize({
    width: PANEL.width * 2,
    height: PANEL.height,
  });

  for (let index = 0; index < options.frames; index += 1) {
    const host = options.startMs + index * STEP;
    const viewer = host - options.delayMs;
    const panel = (ms: number) =>
      `<iframe src="${clock}?t=${Math.round(((ms % CYCLE) + CYCLE) % CYCLE)}"` +
      ` style="width:${PANEL.width}px;height:${PANEL.height}px;border:0"></iframe>`;

    // 親子ともに file:// にする。data: URL の親から file:// の iframe は読み込めない
    await writeFile(
      harness,
      `<body style="margin:0;display:flex;background:#fff">${panel(host)}${panel(viewer)}</body>`,
    );
    await page.goto(`${pathToFileURL(harness).href}?frame=${index}`, {
      waitUntil: "load",
    });
    await page.screenshot({
      path: join(directory, `${String(index + 1).padStart(6, "0")}.png`),
    });
  }

  const video = join(directory, "synthetic.mp4");
  // 実際の撮影も H.264 で来る。可逆で繋ぐと劣化に対する強さを確かめられない
  execFileSync("ffmpeg", [
    "-v",
    "error",
    "-y",
    "-framerate",
    "60",
    "-i",
    join(directory, "%06d.png"),
    "-c:v",
    "libx264",
    "-crf",
    "18",
    "-pix_fmt",
    "yuv420p",
    video,
  ]);
  return video;
}

function analyse(video: string, directory: string): Record<string, number> {
  const output = join(directory, "result.json");
  execFileSync("node", [ANALYZE, video, "--json", output], {
    cwd: WEB,
    stdio: "pipe",
  });
  return JSON.parse(readFileSync(output, "utf8"));
}

test("合成した録画から埋め込んだ遅延を言い当てる", async ({ page }) => {
  const directory = await mkdtemp(join(tmpdir(), "doppelscreen-latency-tool-"));
  try {
    const video = await synthesise(page, directory, {
      delayMs: 50,
      frames: 20,
      startMs: 123_456,
    });
    const result = analyse(video, directory);

    // 合成なので読みはぶれない。ぴったり出るはず
    expect(result.medianMs).toBe(50);
    expect(result.minMs).toBe(50);
    expect(result.maxMs).toBe(50);
    // 全部のコマで 2 つの QR が読めていること。取りこぼすなら QR が小さすぎる
    expect(result.framesUsable).toBe(result.framesAnalyzed);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("カウンタの巡回をまたいでも正しく出る", async ({ page }) => {
  const directory = await mkdtemp(join(tmpdir(), "doppelscreen-latency-wrap-"));
  try {
    // ホストが 0 へ折り返し、ビューアはまだ 999,9xx にいる区間をまたぐ
    const video = await synthesise(page, directory, {
      delayMs: 40,
      frames: 12,
      startMs: CYCLE - 100,
    });
    const result = analyse(video, directory);
    expect(result.medianMs).toBe(40);
    expect(result.framesUsable).toBe(result.framesAnalyzed);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("遅延の求め方（巡回・上限・ホストの判定）", () => {
  // 素直な差
  expect(latencyBetween(1000, 950, 500)).toBe(50);
  // 巡回をまたぐ
  expect(latencyBetween(10, CYCLE - 40, 500)).toBe(50);
  // 上限を超える組は採らない（別物を読んでいる可能性が高い）
  expect(latencyBetween(1000, 100, 500)).toBeNull();
  // 同じ値は遅延 0 ではなく「片方しか読めていない」とみなす
  expect(latencyBetween(1000, 1000, 500)).toBeNull();

  // どちらがホストかは指定しない。新しい方が必ずホスト
  expect(latencyOf([950, 1000], 500)).toBe(50);
  expect(latencyOf([1000, 950], 500)).toBe(50);
  // 1 つしか読めなかったコマは捨てる
  expect(latencyOf([1000], 500)).toBeNull();
  expect(latencyOf([1000, 1000], 500)).toBeNull();
  // 映り込みで 3 つ読めたら、もっとも遅れているものをビューアとみなす
  expect(latencyOf([1000, 980, 950], 500)).toBe(50);
});
