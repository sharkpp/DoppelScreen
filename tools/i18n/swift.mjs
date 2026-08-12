// Apple プラットフォーム（macOS / iOS）向けの出力。
//
// `.lproj/Localizable.strings` をそのまま吐く。システム設定の「言語」やアプリ個別の
// 言語指定に OS 側で追従させるためで、自前の言語選択は持たない。
// 呼び出し側の綴り間違いを消すため、型の付いた入り口（L10n）も併せて生成する。

import { BASE_LANGUAGE, tree } from "./catalog.mjs";

/** `{name}` → `%1$@`。番号は基準言語の出現順で固定する（訳文で語順が変わっても崩れない） */
function toFormat(text, placeholders) {
  return text.replace(/\{([A-Za-z][A-Za-z0-9]*)\}/g, (whole, name) => {
    const index = placeholders.indexOf(name);
    return index < 0 ? whole : `%${index + 1}$@`;
  });
}

function quote(text) {
  return `"${text.replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/\n/g, "\\n")}"`;
}

export function renderStrings(scoped, language) {
  const lines = [
    "/* 自動生成 — 直接編集しない。i18n/*.yaml を直して `make i18n` を実行する */",
    "",
  ];
  for (const entry of scoped.entries) {
    lines.push(`${quote(entry.key)} = ${quote(toFormat(entry.values[language], entry.placeholders))};`);
  }
  return `${lines.join("\n")}\n`;
}

export function renderAccessor(scoped) {
  const lines = [
    "// 自動生成 — 直接編集しない。i18n/*.yaml を直して `make i18n` を実行する。",
    "//",
    "// 実際の文言は <言語>.lproj/Localizable.strings にあり、選択は OS が行う。",
    "// ここが持つのはキーの綴りと引数の型だけ。",
    "",
    "import Foundation",
    "",
    "enum L10n {",
  ];
  emit(tree(scoped.entries), lines, 1);
  lines.push("}");
  return `${lines.join("\n")}\n`;
}

function emit(node, lines, depth) {
  const indent = "    ".repeat(depth);

  for (const leaf of node.leaves) {
    const comment = leaf.values[BASE_LANGUAGE].split("\n")[0];
    lines.push(`${indent}/// ${comment}`);
    if (leaf.placeholders.length === 0) {
      lines.push(`${indent}static var ${leaf.name}: String {`);
      lines.push(`${indent}    NSLocalizedString("${leaf.key}", comment: "")`);
      lines.push(`${indent}}`);
    } else {
      const parameters = leaf.placeholders.map((name) => `${name}: String`).join(", ");
      const arguments_ = leaf.placeholders.join(", ");
      lines.push(`${indent}static func ${leaf.name}(${parameters}) -> String {`);
      lines.push(`${indent}    String(format: NSLocalizedString("${leaf.key}", comment: ""), ${arguments_})`);
      lines.push(`${indent}}`);
    }
    lines.push("");
  }

  for (const [name, child] of node.groups) {
    lines.push(`${indent}enum ${name[0].toUpperCase()}${name.slice(1)} {`);
    emit(child, lines, depth + 1);
    lines.push(`${indent}}`);
    lines.push("");
  }

  // 末尾の空行を落とす
  while (lines[lines.length - 1] === "") lines.pop();
}
