#!/usr/bin/env node
// 言語定義（i18n/<lang>.yaml）を各プラットフォームの形式へ変換する。
//
// 文言の出どころを 1 か所にするための道具。Windows / Android / iOS のホストを足すときは
// ここに出力先を 1 つ追加する（`swift.mjs` と同じ形の render 関数を書く）。
//
//   node tools/i18n/generate.mjs           生成する
//   node tools/i18n/generate.mjs --check   生成物が最新かどうかだけ見る（CI 用）
//
// 生成物はリポジトリに入れる。macOS のビルドに Node を要求しないため。

import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

import { loadCatalog, scope } from "./catalog.mjs";
import { renderAccessor, renderStrings } from "./swift.mjs";
import { renderModule } from "./typescript.mjs";
import { renderCppCatalog } from "./cpp.mjs";
import { renderDart } from "./dart.mjs";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const source = join(root, "i18n");

/**
 * 出力先。`prefix` はその出力先が受け持つキーの範囲で、ビューアの HTML に
 * ホスト UI の文言が混ざらないようにするためにある。
 */
const targets = [
  {
    name: "macOS ホスト",
    prefix: "host",
    render(scoped) {
      const files = {
        "apps/macos/Sources/Generated/L10n.swift": renderAccessor(scoped),
      };
      for (const language of scoped.languages) {
        files[`apps/macos/Sources/Resources/${language}.lproj/Localizable.strings`] = renderStrings(
          scoped,
          language,
        );
      }
      return files;
    },
  },
  {
    // ウィンドウの中身は全 OS で共通の Flutter（docs/adr/0002-host-ui-flutter.md）。
    // トレイ / メニューバーなど、ネイティブ側に残る文言は各 OS の出力を使う
    name: "ホスト UI（Flutter）",
    prefix: "host",
    render(scoped) {
      return { "apps/host_ui/lib/generated/strings.dart": renderDart(scoped) };
    },
  },
  {
    name: "Windows ホスト",
    prefix: "host",
    render(scoped) {
      return { "apps/windows/src/generated/strings.hpp": renderCppCatalog(scoped) };
    },
  },
  {
    name: "Web ビューア",
    prefix: "viewer",
    render(scoped) {
      return { "apps/web/src/generated/strings.ts": renderModule(scoped) };
    },
  },
];

const check = process.argv.includes("--check");
const catalog = loadCatalog(source);

let stale = 0;
for (const target of targets) {
  const scoped = scope(catalog, target.prefix);
  if (scoped.entries.length === 0) {
    throw new Error(`${target.name}: ${target.prefix}.* のキーが 1 つもありません`);
  }

  for (const [path, contents] of Object.entries(target.render(scoped))) {
    const absolute = join(root, path);
    if (safeRead(absolute) === contents) continue;

    if (check) {
      console.error(`古い: ${relative(root, absolute)}`);
      stale += 1;
      continue;
    }
    mkdirSync(dirname(absolute), { recursive: true });
    writeFileSync(absolute, contents);
    console.log(`書き出し: ${relative(root, absolute)}`);
  }
}

if (check && stale > 0) {
  console.error(`\n${stale} 件が古くなっています。\`make i18n\` を実行してください。`);
  process.exit(1);
}

if (check) console.log(`言語定義は最新です（${catalog.languages.join(", ")}）`);

function safeRead(path) {
  try {
    return readFileSync(path, "utf8");
  } catch {
    return null;
  }
}
