import QRCode from "qrcode";
import "./clock.css";
import {
  CYCLE_MS,
  QR_VERSION,
  QR_ERROR_CORRECTION,
  formatPayload,
} from "./payload";

/**
 * glass-to-glass 実測用のカウンタ（SPEC.md §3.3）。
 *
 * ホスト画面に全画面表示し、ホストとビューアを 1 台のカメラで同時に撮る。同じコマに
 * 写った 2 つのカウンタの差が、そのまま遅延になる。
 *
 * 読み取り手段を 3 つ重ねてある。**上から順に、自動化に向く。**
 *
 * 1. **QR** — `latency/analyze.mjs` が録画から自動で読む。位置と時刻の両方が取れるので、
 *    どちらの画面かを人が指定する必要がない（時刻が新しい方が必ずホスト）
 * 2. **数字** — QR が読めないときに人が読む。QR と同じ時刻の下 4 桁
 * 3. **ブロック** — 1 個 = 表示 1 フレーム。桁がブレて読めないコマでも位置の差は残る
 *
 * フレームごとに全体が描き替わるので、キャプチャ側の「変化駆動」（SPEC.md §4.2）も
 * 同時に働く。静止画を映して測ると、静止時の送出停止が効いて何も流れない。
 *
 * `?t=<ミリ秒>` を付けると、その時刻で静止した状態を 1 枚だけ描く。
 * 目視での確認と、`analyze.mjs` 自体の検証（`e2e/latency-tool.spec.ts`）に使う。
 */

const BLOCKS = 12;
/** QR の余白（モジュール数）。仕様上 4 が必要だが、白地の余白は画面全体で確保する */
const QUIET = 2;

const canvas = document.querySelector<HTMLCanvasElement>("#qr")!;
const context = canvas.getContext("2d")!;
const msLabel = document.querySelector<HTMLDivElement>("#ms")!;
const hzLabel = document.querySelector<HTMLElement>("#hz")!;
const periodLabel = document.querySelector<HTMLElement>("#period")!;
const row = document.querySelector<HTMLDivElement>("#blocks")!;

document.querySelector<HTMLElement>("#cycle")!.textContent =
  `${CYCLE_MS / 1000} 秒`;

const cells = Array.from({ length: BLOCKS }, () => {
  const cell = document.createElement("div");
  row.append(cell);
  return cell;
});

// QR は 21x21（version 1）で固定する。モジュールが大きいほど、離れた場所から撮っても
// ビューア側で縮小されても読める。桁数を増やして version が上がると逆に読めなくなる
const modules = QR_VERSION * 4 + 17;
const pixels = modules + QUIET * 2;

// 等倍のオフスクリーンへ描いて拡大する。1 モジュール 1 ピクセルで作れば、
// フレームごとに 441 個の矩形を塗るより速く、境界も濁らない
const stencil = document.createElement("canvas");
stencil.width = pixels;
stencil.height = pixels;
const stencilContext = stencil.getContext("2d")!;
const image = stencilContext.createImageData(pixels, pixels);

function drawQR(payload: string): void {
  const qr = QRCode.create(payload, {
    version: QR_VERSION,
    errorCorrectionLevel: QR_ERROR_CORRECTION,
  });

  // 余白は白。QR の外周に白がないと finder pattern が見つからない
  image.data.fill(255);
  for (let y = 0; y < modules; y += 1) {
    for (let x = 0; x < modules; x += 1) {
      if (!qr.modules.data[y * modules + x]) continue;
      const offset = ((y + QUIET) * pixels + (x + QUIET)) * 4;
      image.data[offset] = 0;
      image.data[offset + 1] = 0;
      image.data[offset + 2] = 0;
    }
  }
  stencilContext.putImageData(image, 0, 0);

  context.imageSmoothingEnabled = false;
  context.drawImage(stencil, 0, 0, canvas.width, canvas.height);
}

let lit = -1;

function render(elapsed: number, interval: number): void {
  drawQR(formatPayload(elapsed));
  msLabel.textContent = String(Math.floor(elapsed % 10000)).padStart(4, "0");

  const index = Math.floor((elapsed % (interval * BLOCKS)) / interval);
  if (index !== lit) {
    if (lit >= 0) cells[lit]!.classList.remove("on");
    cells[index]!.classList.add("on");
    lit = index;
  }

  hzLabel.textContent = `${interval.toFixed(1)}ms / ${(1000 / interval).toFixed(1)}Hz`;
  periodLabel.textContent = `${interval.toFixed(1)}ms`;
}

/** 描画のたびに 1 モジュールが整数ピクセルに乗るよう、辺を pixels の倍数に合わせる */
function resize(): void {
  const side = Math.min(window.innerWidth, window.innerHeight) * 0.6;
  const scale = Math.max(2, Math.floor((side * devicePixelRatio) / pixels));
  canvas.width = pixels * scale;
  canvas.height = pixels * scale;
  canvas.style.width = `${(pixels * scale) / devicePixelRatio}px`;
  canvas.style.height = canvas.style.width;
}

resize();

const frozen = new URLSearchParams(location.search).get("t");
if (frozen !== null) {
  // 静止モード。1 枚だけ描いて止まる
  document.body.dataset.frozen = "true";
  render(Number(frozen), 1000 / 60);
} else {
  window.addEventListener("resize", () => {
    resize();
    lit = -1;
  });

  // 表示のリフレッシュレートは実測する。60Hz を前提に「1 ブロック 16.7ms」と
  // 決め打ちすると、120Hz の画面や省電力で落ちている状態で黙って倍ずれる
  let interval = 1000 / 60;
  let previous: number | undefined;
  const start = performance.now();

  const tick = (now: number) => {
    requestAnimationFrame(tick);

    if (previous !== undefined) {
      const delta = now - previous;
      // 外れ値（タブの復帰など）は捨てて、ゆっくり追従させる
      if (delta > 4 && delta < 40) interval += (delta - interval) * 0.05;
    }
    previous = now;

    render(now - start, interval);
  };
  requestAnimationFrame(tick);
}
