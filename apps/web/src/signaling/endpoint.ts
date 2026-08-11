/**
 * ビューアが繋ぎに行く先を、開かれている URL から決める。
 *
 * - WebSocket のスキームは必ず `location.protocol` から導出する。
 *   HTTPS ページから `ws:` へ繋ぐと混在コンテンツとしてブロックされる（SPEC.md §5.3）。
 * - トークンは URL fragment に置く。サーバのアクセスログにもリファラにも乗らない。
 * - 映す画面はクエリ `?d=` で運ぶ。画面ごとに URL が分かれる（SPEC.md §5.2）。
 * - 開発時は `vite dev`（:5173）から実ホストへ繋げるように `?host=` を受ける
 *   （docs/STACK.md §1.3）。
 */
export type Endpoint = {
  signalUrl: string;
  token: string;
  /** URL が指す画面。指定がなければ `null`（ホストが主画面を選ぶ） */
  display: number | null;
};

export function resolveEndpoint(location: {
  protocol: string;
  host: string;
  hash: string;
  search: string;
}): Endpoint {
  const scheme = location.protocol === "https:" ? "wss:" : "ws:";
  const query = new URLSearchParams(location.search);
  const override = query.get("host");
  const host = override ?? location.host;
  const display = Number(query.get("d"));
  return {
    signalUrl: `${scheme}//${host}/signal`,
    token: decodeURIComponent(location.hash.replace(/^#/, "")),
    // 0 は「画面なし」を表す値なので指定なしと同じ扱いにする
    display: Number.isInteger(display) && display > 0 ? display : null,
  };
}
