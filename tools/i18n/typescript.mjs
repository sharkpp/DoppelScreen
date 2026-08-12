// ビューア（TypeScript）向けの出力。
//
// ビューアは単一 HTML にバンドルされて配信される（docs/STACK.md §6.1）ため、
// 言語ファイルを実行時に取りに行く経路を持てない。**全言語をコードに埋め込み、
// 読み込み時に 1 度だけ選ぶ。** ブラウザの表示言語は途中で変わらない。

import { BASE_LANGUAGE, tree } from "./catalog.mjs";

function quote(text) {
  return JSON.stringify(text);
}

export function renderModule(scoped) {
  const lines = [
    "// 自動生成 — 直接編集しない。i18n/*.yaml を直して `make i18n` を実行する。",
    "",
    `export type Language = ${scoped.languages.map(quote).join(" | ")};`,
    "",
    `const BASE: Language = ${quote(BASE_LANGUAGE)};`,
    "",
    "// キーを有限のユニオンで持つ。綴りを間違えた参照はコンパイルで落ちる",
    "type Key =",
    ...scoped.entries.map((entry, index) => {
      const suffix = index === scoped.entries.length - 1 ? ";" : "";
      return `  | ${quote(entry.key)}${suffix}`;
    }),
    "",
    "const messages: Record<Language, Record<Key, string>> = {",
  ];

  for (const language of scoped.languages) {
    lines.push(`  ${quote(language)}: {`);
    for (const entry of scoped.entries) {
      lines.push(`    ${quote(entry.key)}: ${quote(entry.values[language])},`);
    }
    lines.push("  },");
  }

  lines.push(
    "};",
    "",
    "/**",
    " * ブラウザの表示言語から 1 つ選ぶ。地域まで一致しなくてよい（`en-GB` は `en` として扱う）。",
    " * どれとも合わなければ基準言語へ落とす。",
    " */",
    "export function resolveLanguage(preferred: readonly string[]): Language {",
    "  for (const tag of preferred) {",
    "    const primary = tag.toLowerCase().split(\"-\")[0];",
    "    const match = (Object.keys(messages) as Language[]).find((language) => language === primary);",
    "    if (match) return match;",
    "  }",
    "  return BASE;",
    "}",
    "",
    "export const language: Language = resolveLanguage(",
    "  typeof navigator === \"undefined\" ? [] : (navigator.languages ?? [navigator.language]),",
    ");",
    "",
    "const table = messages[language];",
    "",
    "function format(text: string, values: Record<string, string>): string {",
    "  return text.replace(",
    "    /\\{([A-Za-z][A-Za-z0-9]*)\\}/g,",
    "    (whole, name: string) => values[name] ?? whole,",
    "  );",
    "}",
    "",
    "/** 文言。プレースホルダを持つものだけ関数になる */",
    "export const t = {",
  );

  emit(tree(scoped.entries), lines, 1);
  lines.push("};");
  return `${lines.join("\n")}\n`;
}

function emit(node, lines, depth) {
  const indent = "  ".repeat(depth);

  for (const leaf of node.leaves) {
    lines.push(`${indent}/** ${leaf.values[BASE_LANGUAGE].split("\n")[0]} */`);
    if (leaf.placeholders.length === 0) {
      lines.push(`${indent}${leaf.name}: table[${quote(leaf.key)}],`);
    } else {
      const parameters = leaf.placeholders.map((name) => `${name}: string`).join("; ");
      lines.push(
        `${indent}${leaf.name}: (values: { ${parameters} }) => format(table[${quote(leaf.key)}], values),`,
      );
    }
  }

  for (const [name, child] of node.groups) {
    lines.push(`${indent}${name}: {`);
    emit(child, lines, depth + 1);
    lines.push(`${indent}},`);
  }
}
