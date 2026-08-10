/**
 * ビューアが繋ぎに行く先を、開かれている URL から決める。
 *
 * - WebSocket のスキームは必ず `location.protocol` から導出する。
 *   HTTPS ページから `ws:` へ繋ぐと混在コンテンツとしてブロックされる（SPEC.md §5.3）。
 * - トークンは URL fragment に置く。サーバのアクセスログにもリファラにも乗らない。
 * - 開発時は `vite dev`（:5173）から実ホストへ繋げるように `?host=` を受ける
 *   （docs/STACK.md §1.3）。
 */
export type Endpoint = {
  signalUrl: string;
  token: string;
};

export function resolveEndpoint(location: {
  protocol: string;
  host: string;
  hash: string;
  search: string;
}): Endpoint {
  const scheme = location.protocol === "https:" ? "wss:" : "ws:";
  const override = new URLSearchParams(location.search).get("host");
  const host = override ?? location.host;
  return {
    signalUrl: `${scheme}//${host}/signal`,
    token: decodeURIComponent(location.hash.replace(/^#/, "")),
  };
}
