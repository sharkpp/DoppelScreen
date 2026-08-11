import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { expect, test, type Page } from "@playwright/test";
// @ts-expect-error 実行用のスクリプトなので型定義を持たない。純粋関数だけを借りる
import { captureRate, latencyBetween, readingOf } from "../latency/analyze.mjs";

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
 *
 * `captureIntervalMs` は撮影機の 1 コマぶんの実時間、`containerFps` はその動画が
 * 名乗るフレームレート。**両者を食い違わせるとスローモーション動画になる**
 * （240fps で撮って 30fps の尺で書き出したもの）。
 *
 * 表示は 60Hz なので、カウンタの値は 16.7ms 刻みに量子化する。240fps で撮れば
 * 4 コマ続けて同じ QR になる — 実際の撮影と同じ形にしておく。
 */
async function synthesise(
  page: Page,
  directory: string,
  options: {
    delayMs: number;
    frames: number;
    startMs: number;
    captureIntervalMs?: number;
    containerFps?: number;
  },
): Promise<string> {
  const clock = pathToFileURL(CLOCK).href;
  const harness = join(directory, "harness.html");
  const captureIntervalMs = options.captureIntervalMs ?? STEP;
  const containerFps =
    options.containerFps ?? Math.round(1000 / captureIntervalMs);

  await page.setViewportSize({
    width: PANEL.width * 2,
    height: PANEL.height,
  });

  // 表示は 60Hz。撮影がそれより速ければ、同じ表示フレームが何コマも写る。
  // コマ数で割る（時刻を割らない）— 浮動小数の境目で「1 コマで表示 1 フレーム進む」
  // という物理的にありえないコマを作ってしまう
  const perDisplayFrame = Math.max(1, Math.round(STEP / captureIntervalMs));

  for (let index = 0; index < options.frames; index += 1) {
    const host = options.startMs + Math.floor(index / perDisplayFrame) * STEP;
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
    String(containerFps),
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

/** `latency/analyze.mjs --json` が書く内容 */
type Result = {
  source: { width: number; height: number; containerFps: number };
  captureFps: number | null;
  frameIntervalMs: number | null;
  framesAnalyzed: number;
  framesUsable: number;
  medianMs: number;
  minMs: number;
  maxMs: number;
};

function analyse(
  video: string,
  directory: string,
): { result: Result; output: string } {
  const json = join(directory, "result.json");
  const output = execFileSync("node", [ANALYZE, video, "--json", json], {
    cwd: WEB,
    encoding: "utf8",
  });
  return { result: JSON.parse(readFileSync(json, "utf8")), output };
}

test("合成した録画から埋め込んだ遅延を言い当てる", async ({ page }) => {
  const directory = await mkdtemp(join(tmpdir(), "doppelscreen-latency-tool-"));
  try {
    const video = await synthesise(page, directory, {
      delayMs: 50,
      frames: 20,
      startMs: 123_456,
    });
    const { result } = analyse(video, directory);

    // 合成なので読みはぶれない。ぴったり出るはず
    expect(result.medianMs).toBe(50);
    expect(result.minMs).toBe(50);
    expect(result.maxMs).toBe(50);
    // 全部のコマで 2 つの QR が読めていること。取りこぼすなら QR が小さすぎる
    expect(result.framesUsable).toBe(result.framesAnalyzed);
    // 撮影レートも当てる（60Hz 刻みで撮ったので 60fps）
    expect(result.captureFps).toBeCloseTo(60, 0);
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
    const { result } = analyse(video, directory);
    expect(result.medianMs).toBe(40);
    expect(result.framesUsable).toBe(result.framesAnalyzed);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

/**
 * iPhone のスローモーションは、240fps で撮ったコマを 30fps 再生の尺で書き出す。
 * コンテナの `avg_frame_rate` は 30 になるが、**コマは間引かれていない**ので
 * 遅延の測定には影響しない。撮影レートだけが正しく出る必要がある。
 */
test("スローモーション動画でも撮影レートを言い当てる", async ({ page }) => {
  const directory = await mkdtemp(
    join(tmpdir(), "doppelscreen-latency-slomo-"),
  );
  try {
    const video = await synthesise(page, directory, {
      delayMs: 50,
      frames: 32,
      startMs: 500_000,
      // 240fps で撮り、30fps の尺で書き出す（8 倍に伸びる）
      captureIntervalMs: 1000 / 240,
      containerFps: 30,
    });
    const { result, output } = analyse(video, directory);

    expect(result.source.containerFps).toBeCloseTo(30, 0);
    expect(result.captureFps).toBeCloseTo(240, -1);
    expect(output).toContain("スローモーション");
    // 尺が伸びていても遅延そのものは変わらない
    expect(result.medianMs).toBe(50);
    // 240fps なら分解能の警告は出ない
    expect(output).not.toContain("粗すぎます");
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
  expect(readingOf([950, 1000], 500)).toEqual({ latencyMs: 50, hostMs: 1000 });
  expect(readingOf([1000, 950], 500)).toEqual({ latencyMs: 50, hostMs: 1000 });
  // 1 つしか読めなかったコマは捨てる
  expect(readingOf([1000], 500)).toBeNull();
  expect(readingOf([1000, 1000], 500)).toBeNull();
  // 映り込みで 3 つ読めたら、もっとも遅れているものをビューアとみなす
  expect(readingOf([1000, 980, 950], 500)).toEqual({
    latencyMs: 50,
    hostMs: 1000,
  });
});

test("撮影レートはコンテナではなくホストの時刻から算出する", () => {
  const display = 1000 / 60;

  // 240fps で 60Hz の表示を撮ると、4 コマ続けて同じ値になる。
  // 1 コマごとの差は 0 が並ぶだけなので、値が変わったコマを拾う必要がある
  const readings = Array.from({ length: 24 }, (_, index) => ({
    index,
    hostMs: Math.floor((index * (1000 / 240)) / display) * display,
  }));
  const rate = captureRate(readings)!;
  expect(rate.fps).toBeCloseTo(240, 0);
  expect(rate.intervalMs).toBeCloseTo(1000 / 240, 1);

  // 巡回をまたいでも続く（3 コマに 1 回値が変わる = 180fps）
  expect(
    captureRate([
      { index: 0, hostMs: CYCLE - display * 2 },
      { index: 3, hostMs: CYCLE - display },
      { index: 6, hostMs: 0 },
      { index: 9, hostMs: display },
    ])!.fps,
  ).toBeCloseTo(180, 0);

  // 判断できない場合は黙って null（値が変わっていない / コマが 1 枚）
  expect(captureRate([{ index: 0, hostMs: 10 }])).toBeNull();
  expect(
    captureRate([
      { index: 0, hostMs: 10 },
      { index: 4, hostMs: 10 },
    ]),
  ).toBeNull();
});
