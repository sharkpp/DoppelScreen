// 言語定義（i18n/<lang>.yaml）の読み込みと検証。
//
// プラットフォーム固有の知識はここに持たない。出力側（swift.mjs / typescript.mjs）が
// この結果だけを見て各フレームワークの形式へ変換する。

import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { parse } from "yaml";

/** 基準となる言語。他の言語はこれと同じキー・同じプレースホルダを持たなければならない */
export const BASE_LANGUAGE = "ja";

/** `{name}` 形式のプレースホルダ */
const PLACEHOLDER = /\{([A-Za-z][A-Za-z0-9]*)\}/g;

/**
 * @typedef {{ key: string, placeholders: string[], values: Record<string, string> }} Entry
 * @typedef {{ languages: string[], entries: Entry[] }} Catalog
 */

/** @returns {Catalog} */
export function loadCatalog(directory) {
  const languages = readdirSync(directory)
    .filter((name) => name.endsWith(".yaml"))
    .map((name) => name.replace(/\.yaml$/, ""))
    .sort((a, b) => (a === BASE_LANGUAGE ? -1 : b === BASE_LANGUAGE ? 1 : a.localeCompare(b)));

  if (!languages.includes(BASE_LANGUAGE)) {
    throw new Error(`基準言語 ${BASE_LANGUAGE}.yaml が ${directory} にありません`);
  }

  const tables = Object.fromEntries(
    languages.map((language) => [
      language,
      flatten(parse(readFileSync(join(directory, `${language}.yaml`), "utf8")) ?? {}),
    ]),
  );

  const base = tables[BASE_LANGUAGE];
  const problems = [];

  for (const language of languages) {
    if (language === BASE_LANGUAGE) continue;
    const table = tables[language];
    for (const key of Object.keys(base)) {
      if (!(key in table)) problems.push(`${language}.yaml: ${key} が訳されていません`);
    }
    for (const key of Object.keys(table)) {
      if (!(key in base)) problems.push(`${language}.yaml: ${key} は ${BASE_LANGUAGE}.yaml にありません`);
    }
  }

  const entries = Object.keys(base)
    .sort()
    .map((key) => {
      const placeholders = placeholdersOf(base[key]);
      for (const language of languages) {
        const value = tables[language][key];
        if (value === undefined) continue;
        // 訳文が置き換え先を落とす／増やすと、実行時に埋まらない穴になる。
        // 順序は言語ごとに変わってよい（書式指定子は番号付きで出す）
        if (!sameSet(placeholdersOf(value), placeholders)) {
          problems.push(
            `${language}.yaml: ${key} のプレースホルダが基準と違います（{${placeholders.join("} {")}} を期待）`,
          );
        }
      }
      return {
        key,
        placeholders,
        values: Object.fromEntries(languages.map((language) => [language, tables[language][key]])),
      };
    });

  if (problems.length > 0) {
    throw new Error(`言語定義に不足があります:\n  ${problems.join("\n  ")}`);
  }

  return { languages, entries };
}

/** 出力先ごとに担当する範囲を切り出す。ビューアの HTML にホスト UI の文言を混ぜない */
export function scope(catalog, prefix) {
  return {
    languages: catalog.languages,
    entries: catalog.entries
      .filter((entry) => entry.key.startsWith(`${prefix}.`))
      .map((entry) => ({ ...entry, path: entry.key.slice(prefix.length + 1).split(".") })),
  };
}

/** 出現順のプレースホルダ名（重複は除く）。書式指定子の番号はこの順で決まる */
function placeholdersOf(text) {
  const names = [];
  for (const match of String(text).matchAll(PLACEHOLDER)) {
    if (!names.includes(match[1])) names.push(match[1]);
  }
  return names;
}

function sameSet(a, b) {
  return a.length === b.length && [...a].sort().join() === [...b].sort().join();
}

/** ネストした YAML を `a.b.c` のキーへ潰す */
function flatten(value, prefix = "", into = {}) {
  for (const [key, child] of Object.entries(value)) {
    const path = prefix ? `${prefix}.${key}` : key;
    if (child !== null && typeof child === "object" && !Array.isArray(child)) {
      flatten(child, path, into);
    } else {
      into[path] = String(child);
    }
  }
  return into;
}

/** ネストしたキーから木を組み立てる。生成側が入れ子の型を作るのに使う */
export function tree(entries) {
  const root = { groups: new Map(), leaves: [] };
  for (const entry of entries) {
    let node = root;
    for (const segment of entry.path.slice(0, -1)) {
      if (!node.groups.has(segment)) node.groups.set(segment, { groups: new Map(), leaves: [] });
      node = node.groups.get(segment);
    }
    node.leaves.push({ ...entry, name: entry.path[entry.path.length - 1] });
  }
  return root;
}
