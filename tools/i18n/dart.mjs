// ホスト UI（Flutter / Dart）向けの出力（docs/adr/0002-host-ui-flutter.md）。
//
// ホスト UI はネイティブのアプリに埋め込むため、Flutter の gen-l10n（ARB + Localizations）の
// 仕組みを持ち込まない。**全言語をコードに埋め込み、起動時に 1 度だけ選ぶ**（ビューアと同じ）。
// 呼び出し側の綴り間違いを消すため、入れ子の入り口（`L10n.connection.approve`）を生成する。

import { BASE_LANGUAGE, tree } from "./catalog.mjs";

/** Dart の文字列リテラル。JSON の書式は Dart とほぼ同じで、`$` だけ補間になるので逃がす */
function quote(text) {
  return JSON.stringify(text).replaceAll("$", "\\$");
}

function pascal(segments) {
  return segments.map((segment) => segment[0].toUpperCase() + segment.slice(1)).join("");
}

export function renderDart(scoped) {
  const lines = [
    "// 自動生成 — 直接編集しない。i18n/*.yaml を直して `make i18n` を実行する。",
    "",
    "import 'dart:ui' show Locale, PlatformDispatcher;",
    "",
    `const _base = ${quote(BASE_LANGUAGE)};`,
    "",
    "const _messages = <String, Map<String, String>>{",
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
    "/// OS の表示言語から 1 つ選ぶ。地域まで一致しなくてよい（`en-GB` は `en` として扱う）。",
    "/// どれとも合わなければ基準言語へ落とす（ネイティブ側の .lproj と同じ振る舞い）。",
    "String resolveLanguage(Iterable<Locale> preferred) {",
    "  for (final locale in preferred) {",
    "    if (_messages.containsKey(locale.languageCode)) return locale.languageCode;",
    "  }",
    "  return _base;",
    "}",
    "",
    "final String language = resolveLanguage(PlatformDispatcher.instance.locales);",
    "",
    "final Map<String, String> _table = _messages[language]!;",
    "",
    "final _placeholder = RegExp(r'\\{([A-Za-z][A-Za-z0-9]*)\\}');",
    "",
    "String _format(String text, Map<String, String> values) =>",
    "    text.replaceAllMapped(_placeholder, (match) => values[match[1]] ?? match[0]!);",
  );

  const classes = [];
  collect(tree(scoped.entries), [], classes);
  for (const { name, node, root } of classes) {
    lines.push("");
    if (root) {
      lines.push("/// 文言。プレースホルダを持つものだけ関数になる");
      lines.push(`abstract final class ${name} {`);
    } else {
      lines.push(`final class ${name} {`);
      lines.push(`  const ${name}._();`);
    }
    emit(node, name, root, lines);
    lines.push("}");
  }

  return `${lines.join("\n")}\n`;
}

/** 入れ子のグループを 1 つずつクラスにする。名前は経路をつなげたもの（`L10nConnection`） */
function collect(node, path, into) {
  into.push({ name: `L10n${pascal(path)}`, node, root: path.length === 0 });
  for (const [segment, child] of node.groups) collect(child, [...path, segment], into);
}

function emit(node, name, root, lines) {
  // ルートは static、グループはインスタンスのメンバにする（`L10n.connection.approve`）
  const modifier = root ? "static " : "";

  for (const [segment] of node.groups) {
    const child = `${name}${pascal([segment])}`;
    lines.push(`  ${modifier}const ${segment} = ${child}._();`);
  }

  for (const leaf of node.leaves) {
    lines.push("");
    lines.push(`  /// ${leaf.values[BASE_LANGUAGE].split("\n")[0]}`);
    const lookup = `_table[${quote(leaf.key)}]!`;
    if (leaf.placeholders.length === 0) {
      lines.push(`  ${modifier}String get ${leaf.name} => ${lookup};`);
    } else {
      const parameters = leaf.placeholders.map((placeholder) => `required String ${placeholder}`).join(", ");
      const values = leaf.placeholders.map((placeholder) => `${quote(placeholder)}: ${placeholder}`).join(", ");
      lines.push(`  ${modifier}String ${leaf.name}({${parameters}}) =>`);
      lines.push(`      _format(${lookup}, {${values}});`);
    }
  }
}
