/**
 * HTTPS 経路への誘導（SPEC.md §5.3）。
 *
 * 既定は HTTP。証明書の警告が出ないため、成立する環境ではこちらが最良の体験になる。
 * ただしブラウザが `RTCPeerConnection` にセキュアコンテキストを要求する場合は使えないため、
 * **そのときだけ** HTTPS への切り替えを案内する。
 *
 * HTTPS のポートは待受を始めるまで決まらないので、ホストの `/config` に尋ねる。
 * HTML へ埋め込ませると、ホストが成果物を書き換えることになる（docs/STACK.md §6.1）。
 */
export function secureURL(
  location: {
    protocol: string;
    hostname: string;
    search: string;
    hash: string;
  },
  securePort: number | null,
): string | null {
  if (location.protocol === "https:" || securePort === null) return null;
  // クエリごと引き継ぐ。`?d=` を落とすと、切り替えた先で別の画面が映る（SPEC.md §5.2）
  return `https://${location.hostname}:${securePort}/${location.search}${location.hash}`;
}

export async function fetchSecurePort(): Promise<number | null> {
  try {
    const response = await fetch("/config", { cache: "no-store" });
    const config: unknown = await response.json();
    const port = (config as { securePort?: unknown })?.securePort;
    return typeof port === "number" ? port : null;
  } catch {
    return null;
  }
}
