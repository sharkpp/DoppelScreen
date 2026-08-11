/**
 * QR に載せる値の決め方。
 *
 * **`latency/analyze.mjs` の `CYCLE_MS` と対になっている。** 片方を変えたら両方変える
 * （シグナリングの Swift / TS 対と同じ扱い — docs/STACK.md §6.3）。
 */

/**
 * QR に載せるミリ秒の周期。1000 秒。
 *
 * 桁数がそのまま QR の版に効くので、短いほど読みやすい。6 桁なら version 1 の
 * 数字モード（誤り訂正 H で 17 文字）に収まり、21x21 モジュールで済む。
 * 周期は「撮影 1 回ぶんの長さ + 遅延」より十分長ければよく、1000 秒あれば足りる。
 */
export const CYCLE_MS = 1_000_000;

/** 21x21 モジュール。離れた場所から撮ってもビューア側で縮小されても読める大きさ */
export const QR_VERSION = 1;

/** カメラ越しなので誤り訂正は最大にする */
export const QR_ERROR_CORRECTION = "H" as const;

/** 経過ミリ秒を QR に載せる 6 桁へ。桁数を固定しないと版が揺れる */
export function formatPayload(elapsedMs: number): string {
  const value = Math.floor(elapsedMs) % CYCLE_MS;
  return String(value).padStart(String(CYCLE_MS - 1).length, "0");
}
