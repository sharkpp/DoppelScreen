// 制御チャネル（SPEC.md §7）で流すメッセージ。
//
// 映像は SRTP で流れる。DataChannel `control` はメタ情報のためだけに 1 本だけ持つ。
// JSON、1 メッセージ 1 イベント。`apps/macos/Sources/Session/ControlMessage.swift` と対になっている。
//
// シグナリング（`signaling/messages.ts`）とは別物。あちらは接続確立にだけ使う。
// パースは純粋関数として切り出し、ブラウザなしでテストする（docs/STACK.md §6.3）。

export type ControlDisplay = {
  id: number;
  name: string;
  /** 物理ピクセル単位のサイズ */
  w: number;
  h: number;
  scale: number;
};

/** 品質プリセット（SPEC.md §7.2）。ビューアが選び、ホストが当てる */
export const QUALITY_PRESETS = ["sharp", "balanced", "smooth"] as const;
export type QualityPreset = (typeof QUALITY_PRESETS)[number];

/** ホスト → ビューア */
export type HostControl =
  | { t: "hello"; platform: string; display: ControlDisplay }
  | ({ t: "display" } & ControlDisplay)
  /** 繋ぎ直すための使い切りチケット（SPEC.md §11-4） */
  | { t: "resume"; ticket: string; ttlMs: number }
  | { t: "stats"; fps: number; bitrate: number; encodeMs: number }
  /** 理由は**コード**で届く。文言はビューアが自分の言語で出す（`errors.ts`） */
  | { t: "error"; code: string; detail: string | null };

/** 表示できる領域の**物理ピクセル**数。ホストはこれに合わせて符号化解像度を決める（SPEC.md §7.1） */
export type ViewportMessage = {
  t: "viewport";
  w: number;
  h: number;
  dpr: number;
};

/** ビューア → ホスト */
export type ViewerControl =
  ViewportMessage | { t: "quality"; preset: QualityPreset };

/**
 * ホストからの制御メッセージを解釈する。解釈できないものは `null` を返して黙って捨てる
 * （版の食い違いで未知のメッセージが来ても接続を落とさない）。
 */
export function parseHostControl(raw: string): HostControl | null {
  let value: unknown;
  try {
    value = JSON.parse(raw);
  } catch {
    return null;
  }
  if (typeof value !== "object" || value === null) return null;
  const message = value as Record<string, unknown>;

  switch (message.t) {
    case "hello": {
      const display = parseDisplay(message.display);
      if (!display || typeof message.platform !== "string") return null;
      return { t: "hello", platform: message.platform, display };
    }
    case "display": {
      const display = parseDisplay(message);
      return display ? { t: "display", ...display } : null;
    }
    case "stats":
      if (typeof message.fps !== "number") return null;
      return {
        t: "stats",
        fps: message.fps,
        bitrate: typeof message.bitrate === "number" ? message.bitrate : 0,
        encodeMs: typeof message.encodeMs === "number" ? message.encodeMs : 0,
      };
    case "resume":
      return typeof message.ticket === "string" &&
        typeof message.ttlMs === "number"
        ? { t: "resume", ticket: message.ticket, ttlMs: message.ttlMs }
        : null;
    case "error":
      return typeof message.code === "string"
        ? {
            t: "error",
            code: message.code,
            detail: typeof message.detail === "string" ? message.detail : null,
          }
        : null;
    default:
      return null;
  }
}

function parseDisplay(value: unknown): ControlDisplay | null {
  if (typeof value !== "object" || value === null) return null;
  const display = value as Record<string, unknown>;
  if (
    typeof display.id !== "number" ||
    typeof display.name !== "string" ||
    typeof display.w !== "number" ||
    typeof display.h !== "number"
  ) {
    return null;
  }
  return {
    id: display.id,
    name: display.name,
    w: display.w,
    h: display.h,
    scale: typeof display.scale === "number" ? display.scale : 1,
  };
}

export function encodeViewerControl(message: ViewerControl): string {
  return JSON.stringify(message);
}

/**
 * ホストへ申告する表示領域（SPEC.md §7.1）。
 *
 * ビューアはアスペクト比を保ってレターボックス表示する（SPEC.md §8.2）ため、
 * 使えるのはウィンドウ全体。CSS ピクセルではなく**物理ピクセル**で申告する
 * （高 DPI 端末で実解像度の半分しか受け取れなくなるのを避ける）。
 */
export function measureViewport(view: {
  innerWidth: number;
  innerHeight: number;
  devicePixelRatio: number;
}): ViewportMessage {
  const dpr = view.devicePixelRatio > 0 ? view.devicePixelRatio : 1;
  return {
    t: "viewport",
    w: Math.round(view.innerWidth * dpr),
    h: Math.round(view.innerHeight * dpr),
    dpr,
  };
}
