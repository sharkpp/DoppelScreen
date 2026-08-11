#!/usr/bin/env node
// 録画した動画から glass-to-glass 遅延を出す（SPEC.md §3.3 / docs/latency-measurements.md）。
//
//   node latency/analyze.mjs <動画> [--every N] [--max-latency 500] [--json 出力先]
//
// ホストとビューアを 1 台のカメラで同時に撮った動画を渡す。各コマから QR を**すべて**
// 読み、時刻の差を取る。**どちらの画面かを指定する必要はない** — ホストは必ず
// ビューアより新しいので、時刻の大小で決まる。
//
// コマごとの読みは表示フレームに量子化されて ±1 フレームぶれるため、
// 全コマの中央値を結果とする。人が 10 コマ読んでいたものを数百コマに増やすだけ。
//
// **撮影レートはコンテナの申告を信じない。QR に載っているホストの時刻から算出する。**
// iPhone のスローモーションは 240fps で撮ったものを 30fps 再生の尺で書き出すため、
// コンテナの `avg_frame_rate` は 30 になる（コマは間引かれていないので測定には影響しない）。

import { execFileSync, spawn } from "node:child_process";
import { writeFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";
import { readBarcodesFromImageData } from "zxing-wasm/reader";

/** latency/payload.ts の CYCLE_MS と対になっている。片方を変えたら両方変える */
const CYCLE_MS = 1_000_000;

/** 同時に読む枚数。QR の探索は CPU 律速なので、並べても速くなるのはコア数まで */
const CONCURRENCY = 8;

/** これを下回ると 1 コマの粗さが目標 60ms に対して無視できない */
const USABLE_FPS = 120;

function parseArguments(argv) {
  const options = { every: 1, maxLatency: 500, json: null };
  const rest = [];
  for (let i = 0; i < argv.length; i += 1) {
    const argument = argv[i];
    switch (argument) {
      case "--every":
        options.every = Number(argv[(i += 1)]);
        break;
      case "--max-latency":
        options.maxLatency = Number(argv[(i += 1)]);
        break;
      case "--json":
        options.json = argv[(i += 1)];
        break;
      default:
        if (argument.startsWith("--")) throw new Error(`不明な引数: ${argument}`);
        rest.push(argument);
    }
  }
  if (rest.length !== 1 || !Number.isInteger(options.every) || options.every < 1) {
    throw new Error(
      "使い方: node latency/analyze.mjs <動画> [--every N] [--max-latency ms] [--json 出力先]",
    );
  }
  return { video: rest[0], ...options };
}

/**
 * コンテナが申告している素性。**撮影レートの判断には使わない**（`captureRate` を使う）。
 * 表示上のフレームレートと実際の撮影レートが食い違っていることを示すために読む。
 */
function probe(video) {
  const raw = execFileSync("ffprobe", [
    "-v", "error",
    "-select_streams", "v:0",
    "-show_entries",
    "stream=width,height,avg_frame_rate,r_frame_rate,nb_frames:format=duration:stream_tags:format_tags",
    "-of", "json",
    video,
  ]);
  const parsed = JSON.parse(raw);
  const stream = parsed.streams?.[0] ?? {};
  const ratio = (value) => {
    const [numerator, denominator] = String(value ?? "0/1").split("/");
    return Number(denominator) ? Number(numerator) / Number(denominator) : 0;
  };

  // 撮影レートの手がかりになりそうなメタデータは、あれば出す。
  // Apple の書くキーに依存した判定はしない（機種と書き出し方で変わる）
  const tags = { ...(parsed.format?.tags ?? {}), ...(stream.tags ?? {}) };
  const hints = Object.entries(tags).filter(([key]) =>
    /frame.?rate|slow|capture|fps/i.test(key),
  );

  return {
    width: stream.width ?? 0,
    height: stream.height ?? 0,
    containerFps: ratio(stream.avg_frame_rate),
    nominalFps: ratio(stream.r_frame_rate),
    durationSeconds: Number(parsed.format?.duration ?? 0),
    hints,
  };
}

/**
 * 2 つの時刻の差。QR の値は CYCLE_MS で巡回するので、巡回をまたいだ組も拾う。
 * 新しい方（ホスト）から古い方（ビューア）を引いた値が遅延になる。
 */
export function latencyBetween(newer, older, maxLatency) {
  const forward = (((newer - older) % CYCLE_MS) + CYCLE_MS) % CYCLE_MS;
  return forward > 0 && forward <= maxLatency ? forward : null;
}

/**
 * 1 コマから読めた QR の集合を「遅延」と「ホストの時刻」に変える。
 *
 * 3 つ以上読めることがある（画面への映り込みなど）。もっとも古い値をビューアとみなし、
 * その中で成立する最大の差を採る — 遅れているほうが本物のビューアである。
 */
export function readingOf(values, maxLatency) {
  const unique = [...new Set(values)];
  if (unique.length < 2) return null;

  let best = null;
  for (const newer of unique) {
    for (const older of unique) {
      if (newer === older) continue;
      const latencyMs = latencyBetween(newer, older, maxLatency);
      if (latencyMs !== null && (best === null || latencyMs > best.latencyMs)) {
        best = { latencyMs, hostMs: newer };
      }
    }
  }
  return best;
}

/**
 * 実際の撮影レート。**ホストの時刻を基準時計として使う。**
 *
 * コンテナの申告ではなく「コマがどれだけ実時間を刻んでいるか」を測るので、
 * スローモーション（240fps で撮って 30fps の尺に伸ばした動画）でも正しく出る。
 *
 * 表示は 60Hz なので、240fps で撮れば 4 コマ続けて同じ QR になる。1 コマごとの差は
 * 0 が並ぶだけで使えない。かわりに**値が変わったコマ（＝表示フレームの境目）だけを拾い、
 * 最初と最後の境目のあいだを数える。**
 *
 * 単純に全体の両端を使うと、端点に「まだ値が変わっていない待ち時間」が最大 1 表示フレーム
 * ぶん乗る。10 秒の録画なら誤差 0.2% だが、短い録画では 240fps が 276fps に化ける。
 * 境目を使えば端点の誤差が 1 撮影コマ未満に収まる。
 *
 * 隣り合う境目どうしの差の中央値は採らない。QR に載る時刻は 1ms に丸めてあるので、
 * 16ms と 17ms が交互に出て数 % の偏りが残る。**最初と最後だけを使えば丸めが打ち消える。**
 * 端点が壊れる心配は要らない — QR は誤り検出を持つので、読めた値は正しい。
 *
 * `readings` は `{ index, hostMs }` を index の昇順で並べたもの。
 */
export function captureRate(readings) {
  const transitions = [];
  for (let i = 1; i < readings.length; i += 1) {
    if (readings[i].hostMs !== readings[i - 1].hostMs) transitions.push(readings[i]);
  }
  if (transitions.length < 2) return null;

  const first = transitions[0];
  const last = transitions[transitions.length - 1];
  // ホストの時刻は増える一方なので、剰余で巡回のまたぎも正しく戻る
  const elapsedMs = (((last.hostMs - first.hostMs) % CYCLE_MS) + CYCLE_MS) % CYCLE_MS;
  const frames = last.index - first.index;

  if (frames <= 0 || elapsedMs <= 0) return null;
  return { fps: (frames / elapsedMs) * 1000, intervalMs: elapsedMs / frames };
}

export function quantile(sorted, fraction) {
  if (sorted.length === 0) return 0;
  const position = (sorted.length - 1) * fraction;
  const low = Math.floor(position);
  const high = Math.ceil(position);
  return sorted[low] + (sorted[high] - sorted[low]) * (position - low);
}

/**
 * ffmpeg から生の RGBA を流し込んでコマごとに読む。
 *
 * 中間ファイルを作らない。1080p の PNG を全コマ書き出すと、10 秒の 240fps 動画で
 * 数 GB になる（そして QR は非可逆圧縮を通すと読めなくなることがあるので、
 * JPEG で軽くするのも避けたい）。
 */
async function readFrames(video, options, onProgress) {
  const { width, height } = options;
  const frameBytes = width * height * 4;

  const args = ["-v", "error", "-i", video];
  if (options.every > 1) {
    // コマ番号で間引く。コンテナの時刻に依存させない（スローモーションで狂う）
    args.push("-vf", `select='not(mod(n\\,${options.every}))'`, "-fps_mode", "passthrough");
  }
  args.push("-f", "rawvideo", "-pix_fmt", "rgba", "-");

  const child = spawn("ffmpeg", args, { stdio: ["ignore", "pipe", "pipe"] });
  let stderr = "";
  child.stderr.on("data", (chunk) => (stderr += chunk));

  const readings = [];
  let index = 0;
  let decoded = 0;
  let buffer = Buffer.alloc(0);
  let batch = [];

  const flush = async () => {
    const current = batch;
    batch = [];
    const results = await Promise.all(
      current.map(async ({ frame, at }) => ({
        at,
        values: await decode(frame, width, height),
      })),
    );
    for (const { at, values } of results) {
      const reading = readingOf(values, options.maxLatency);
      if (values.length > 0) decoded += 1;
      if (reading) readings.push({ index: at, ...reading });
    }
    onProgress(index, readings.length);
  };

  for await (const chunk of child.stdout) {
    buffer = buffer.length === 0 ? chunk : Buffer.concat([buffer, chunk]);
    while (buffer.length >= frameBytes) {
      // zxing へ渡すまでの間に上書きされないよう写す
      batch.push({ frame: Uint8ClampedArray.from(buffer.subarray(0, frameBytes)), at: index });
      buffer = buffer.subarray(frameBytes);
      index += 1;
      if (batch.length >= CONCURRENCY) await flush();
    }
  }
  if (batch.length > 0) await flush();

  const code = await new Promise((resolve) => child.on("close", resolve));
  if (code !== 0) throw new Error(`ffmpeg が失敗しました: ${stderr.trim()}`);

  return { readings, frames: index, framesWithQR: decoded };
}

async function decode(data, width, height) {
  const results = await readBarcodesFromImageData(
    { data, width, height, colorSpace: "srgb" },
    { formats: ["QRCode"], tryHarder: true, maxNumberOfSymbols: 8 },
  );
  return results
    .filter((result) => /^\d+$/.test(result.text))
    .map((result) => Number(result.text));
}

function histogram(samples, interval) {
  const buckets = new Map();
  for (const sample of samples) {
    const bucket = Math.floor(sample / interval) * interval;
    buckets.set(bucket, (buckets.get(bucket) ?? 0) + 1);
  }
  return [...buckets.entries()].sort(([a], [b]) => a - b);
}

async function main() {
  const options = parseArguments(process.argv.slice(2));
  const source = probe(options.video);
  if (source.width === 0 || source.height === 0) {
    throw new Error("映像ストリームが見つかりません");
  }

  console.log(`動画: ${options.video}`);
  console.log(
    `  ${source.width}x${source.height} / ${source.durationSeconds.toFixed(1)}s` +
      ` / コンテナ ${source.containerFps.toFixed(1)}fps（表示上）`,
  );
  for (const [key, value] of source.hints) console.log(`  ${key}: ${value}`);
  if (options.every > 1) console.log(`  ${options.every} コマに 1 枚だけ読みます`);

  const { readings, frames, framesWithQR } = await readFrames(
    options.video,
    { ...options, width: source.width, height: source.height },
    (done, usable) => {
      process.stdout.write(`\r  ${done} コマ / 2 つ読めたコマ ${usable}   `);
    },
  );
  process.stdout.write("\r\x1b[K");

  const rate = captureRate(readings);
  const samples = readings.map((reading) => reading.latencyMs).sort((a, b) => a - b);

  console.log("");
  if (rate) {
    console.log(
      `撮影レート: ${rate.fps.toFixed(1)}fps（1 コマ ${rate.intervalMs.toFixed(1)}ms）` +
        " ← QR の時刻から算出",
    );
    // スローモーションは「コマを間引かずに尺を伸ばす」ので、遅延の測定には影響しない
    if (rate.fps > source.containerFps * 1.5) {
      console.log(
        `  ※ スローモーション: コンテナは ${source.containerFps.toFixed(1)}fps だが、` +
          `実際は ${rate.fps.toFixed(0)}fps で撮られている（コマは間引かれていないので測定に影響しない）`,
      );
    }
    if (rate.fps + 1 < USABLE_FPS) {
      console.log(
        `  ⚠︎ 1 コマ ${rate.intervalMs.toFixed(1)}ms は、目標 60ms に対して粗すぎます` +
          "（240fps 推奨 — docs/latency-measurements.md §2）",
      );
    }
  }

  if (samples.length === 0) {
    console.log("");
    console.log("2 つの QR が同時に読めたコマがありません。");
    console.log(`  QR が写っていたコマ: ${framesWithQR} / ${frames}`);
    console.log(
      framesWithQR === 0
        ? "  → QR がまったく写っていません。ピント・明るさ・画角を確認してください"
        : "  → 片方しか写っていません。ホストとビューアの両方が画面内に入っているか確認してください",
    );
    process.exitCode = 1;
    return;
  }

  const result = {
    video: options.video,
    source: {
      width: source.width,
      height: source.height,
      durationSeconds: source.durationSeconds,
      containerFps: Number(source.containerFps.toFixed(2)),
    },
    captureFps: rate ? Number(rate.fps.toFixed(1)) : null,
    frameIntervalMs: rate ? Number(rate.intervalMs.toFixed(2)) : null,
    framesAnalyzed: frames,
    framesUsable: samples.length,
    medianMs: Number(quantile(samples, 0.5).toFixed(1)),
    minMs: samples[0],
    maxMs: samples[samples.length - 1],
    p10Ms: Number(quantile(samples, 0.1).toFixed(1)),
    p90Ms: Number(quantile(samples, 0.9).toFixed(1)),
  };

  console.log("");
  console.log(`遅延の中央値: ${result.medianMs}ms   （目標 60ms 以下 — SPEC.md §1.3）`);
  console.log(
    `  最小 ${result.minMs}ms / 最大 ${result.maxMs}ms / p10 ${result.p10Ms}ms / p90 ${result.p90Ms}ms`,
  );
  console.log(
    `  読めたコマ ${result.framesUsable} / ${result.framesAnalyzed}` +
      ` (${((result.framesUsable / result.framesAnalyzed) * 100).toFixed(0)}%)`,
  );

  console.log("");
  console.log("分布（1 段 = 10ms）:");
  for (const [bucket, count] of histogram(samples, 10)) {
    const bar = "█".repeat(Math.max(1, Math.round((count / samples.length) * 40)));
    console.log(`  ${String(bucket).padStart(4)}ms ${bar} ${count}`);
  }

  console.log("");
  console.log("docs/latency-measurements.md の表に貼る値:");
  console.log(`  中央値 ${result.medianMs}ms / 最小 ${result.minMs}ms / 最大 ${result.maxMs}ms`);

  if (options.json) {
    await writeFile(options.json, `${JSON.stringify(result, null, 1)}\n`);
    console.log(`  → ${options.json} に書きました`);
  }
}

// 純粋関数は `e2e/latency-tool.spec.ts` から読み込んで直接確かめる。
// 読み込まれただけで動き出さないようにする
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  await main();
}
