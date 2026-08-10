import { defineConfig } from "vitest/config";
import { viteSingleFile } from "vite-plugin-singlefile";

// 成果物を単一 HTML に落とす（docs/STACK.md §1.1）。
// ホスト実装は「1 つのファイルを返すだけ」で済み、静的配信のルーティング・
// MIME 判定・キャッシュ制御がすべて不要になる。ホストが 4 実装あるため効果が大きい。
export default defineConfig({
  plugins: [viteSingleFile()],
  build: {
    target: "es2022",
    // インライン化するので分割させない
    assetsInlineLimit: Number.MAX_SAFE_INTEGER,
    cssCodeSplit: false,
    reportCompressedSize: false,
  },
  // e2e/ は Playwright が持つ。Vitest はブラウザなしで回る単体テストだけを見る
  test: {
    include: ["src/**/*.test.ts"],
  },
});
