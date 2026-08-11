#!/usr/bin/env node
// 録画した動画から glass-to-glass 遅延を出す（SPEC.md §3.3 / docs/latency-measurements.md）。
//
//   node latency/analyze.mjs <動画> [--fps N] [--max-latency 500] [--json 出力先]
//
// ホストとビューアを 1 台のカメラで同時に撮った動画を渡す。各コマから QR を**すべて**
// 読み、時刻の差を取る。**どちらの画面かを指定する必要はない** — ホストは必ず
// ビューアより新しいので、時刻の大小で決まる。
//
// コマごとの読みは表示フレームに量子化されて ±1 フレームぶれるため、
// 全コマの中央値を結果とする。人が 10 コマ読んでいたものを数百コマに増やすだけ。

import { execFile, execFileSync } from "node:child_process";
import { mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { promisify } from "node:util";
import { readBarcodesFromImageFile } from "zxing-wasm/reader";

const run = promisify(execFile);

/** latency/payload.ts の CYCLE_MS と対になっている。片方を変えたら両方変える */
const CYCLE_MS = 1_000_000;

/** 同時に読む枚数。QR の探索は CPU 律速なので、並べても速くなるのはコア数まで */
const CONCURRENCY = 8;

function parseArguments(argv) {
  const options = { fps: null, maxLatency: 500, json: null, keepFrames: false };
  const rest = [];
  for (let i = 0; i < argv.length; i += 1) {
    const argument = argv[i];
    switch (argument) {
      case "--fps":
        options.fps = Number(argv[(i += 1)]);
        break;
      case "--max-latency":
        options.maxLatency = Number(argv[(i += 1)]);
        break;
      case "--json":
        options.json = argv[(i += 1)];
        break;
      case "--keep-frames":
        options.keepFrames = true;
        break;
      default:
        if (argument.startsWith("--")) throw new Error(`不明な引数: ${argument}`);
        rest.push(argument);
    }
  }
  if (rest.length !== 1) {
    throw new Error(
      "使い方: node latency/analyze.mjs <動画> [--fps N] [--max-latency ms] [--json 出力先]",
    );
  }
  return { video: rest[0], ...options };
}

/** 撮影の素性。フレームレートが足りない動画で測っても意味がないので必ず出す */
function probe(video) {
  const raw = execFileSync("ffprobe", [
    "-v", "error",
    "-select_streams", "v:0",
    "-show_entries", "stream=width,height,avg_frame_rate,nb_read_frames",
    "-show_entries", "format=duration",
    "-of", "json",
    video,
  ]);
  const parsed = JSON.parse(raw);
  const stream = parsed.streams?.[0] ?? {};
  const [numerator, denominator] = String(stream.avg_frame_rate ?? "0/1").split("/");
  return {
    width: stream.width ?? 0,
    height: stream.height ?? 0,
    fps: Number(denominator) ? Number(numerator) / Number(denominator) : 0,
    durationSeconds: Number(parsed.format?.duration ?? 0),
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
 * 1 コマから読めた QR の集合を遅延に変える。
 *
 * 3 つ以上読めることがある（画面への映り込みなど）。もっとも古い値をビューアとみなし、
 * その中で成立する最大の差を採る — 遅れているほうが本物のビューアである。
 */
export function latencyOf(values, maxLatency) {
  const unique = [...new Set(values)];
  if (unique.length < 2) return null;

  let best = null;
  for (const newer of unique) {
    for (const older of unique) {
      if (newer === older) continue;
      const candidate = latencyBetween(newer, older, maxLatency);
      if (candidate !== null && (best === null || candidate > best)) best = candidate;
    }
  }
  return best;
}

export function quantile(sorted, fraction) {
  if (sorted.length === 0) return 0;
  const position = (sorted.length - 1) * fraction;
  const low = Math.floor(position);
  const high = Math.ceil(position);
  return sorted[low] + (sorted[high] - sorted[low]) * (position - low);
}

async function decodeFrame(path) {
  const blob = new Blob([await readFile(path)], { type: "image/png" });
  const results = await readBarcodesFromImageFile(blob, {
    formats: ["QRCode"],
    tryHarder: true,
    maxNumberOfSymbols: 8,
  });
  return results
    .filter((result) => /^\d+$/.test(result.text))
    .map((result) => Number(result.text));
}

/** 上限つきの並列処理。全コマを一度に開くとメモリを食う */
async function mapWithLimit(items, limit, worker) {
  const results = new Array(items.length);
  let next = 0;
  await Promise.all(
    Array.from({ length: Math.min(limit, items.length) }, async () => {
      while (true) {
        const index = next;
        next += 1;
        if (index >= items.length) return;
        results[index] = await worker(items[index], index);
      }
    }),
  );
  return results;
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

  console.log(`動画: ${options.video}`);
  console.log(
    `  ${source.width}x${source.height} / ${source.fps.toFixed(1)}fps / ${source.durationSeconds.toFixed(1)}s`,
  );
  if (source.fps < 120) {
    console.log(
      `  ⚠︎ ${source.fps.toFixed(0)}fps では 1 コマ ${(1000 / source.fps).toFixed(1)}ms あり、` +
        "目標 60ms に対して分解能が足りません（240fps 推奨）",
    );
  }

  const directory = await mkdtemp(join(tmpdir(), "doppelscreen-latency-"));
  try {
    const filters = options.fps ? ["-vf", `fps=${options.fps}`] : [];
    await run("ffmpeg", [
      "-v", "error",
      "-i", options.video,
      ...filters,
      // QR はモジュールの境界が濁ると読めない。中間ファイルは可逆にする
      join(directory, "%06d.png"),
    ]);

    const frames = (await readdir(directory)).sort().map((name) => join(directory, name));
    if (frames.length === 0) throw new Error("コマを取り出せませんでした");
    process.stdout.write(`  ${frames.length} コマを解析します…`);

    const readings = await mapWithLimit(frames, CONCURRENCY, async (path) =>
      latencyOf(await decodeFrame(path), options.maxLatency),
    );
    console.log(" 完了");

    const samples = readings.filter((value) => value !== null).sort((a, b) => a - b);
    const result = {
      video: options.video,
      source,
      framesAnalyzed: frames.length,
      framesUsable: samples.length,
      medianMs: Number(quantile(samples, 0.5).toFixed(1)),
      minMs: samples[0] ?? 0,
      maxMs: samples[samples.length - 1] ?? 0,
      p10Ms: Number(quantile(samples, 0.1).toFixed(1)),
      p90Ms: Number(quantile(samples, 0.9).toFixed(1)),
    };

    console.log("");
    if (samples.length === 0) {
      console.log("2 つの QR が同時に読めたコマがありません。");
      console.log("  - ホストとビューアの両方が画面内に入っているか");
      console.log("  - QR が小さすぎないか（カメラを寄せる / ビューアを大きい端末にする）");
      console.log("  - ピントと明るさ（QR は白地に黒。反射で飛んでいないか）");
      process.exitCode = 1;
      return;
    }

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
  } finally {
    if (options.keepFrames) console.log(`コマを残しました: ${directory}`);
    else await rm(directory, { recursive: true, force: true });
  }
}

// 純粋関数は `e2e/latency-tool.spec.ts` から読み込んで直接確かめる。
// 読み込まれただけで動き出さないようにする
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  await main();
}
