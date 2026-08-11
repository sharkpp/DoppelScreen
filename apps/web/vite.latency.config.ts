import { defineConfig } from "vite";
import { viteSingleFile } from "vite-plugin-singlefile";

// glass-to-glass 計測用カウンタ（docs/latency-measurements.md）。
//
// ビューア本体（vite.config.ts）とは別のビルドにする。同じビルドに混ぜると
// 出力先を食い合い、ホストのバンドルへ入れるファイルがどちらか分からなくなる。
//
// 単一 HTML に落とす理由はビューアと同じで、file:// でそのまま開けるようにするため。
// 撮影機と同じ端末にサーバを立てさせない。
export default defineConfig({
  root: "latency",
  plugins: [viteSingleFile()],
  build: {
    target: "es2022",
    outDir: "dist",
    emptyOutDir: true,
    assetsInlineLimit: Number.MAX_SAFE_INTEGER,
    cssCodeSplit: false,
    reportCompressedSize: false,
    rollupOptions: { input: "latency/clock.html" },
  },
});
