import "./style.css";
import {
  measureViewport,
  QUALITY_PRESETS,
  type QualityPreset,
} from "./control";
import { describeError } from "./errors";
import { t } from "./generated/strings";
import { format, summarize, type Sample, type StatsEntry } from "./latency";
import { ViewerSession, type SessionState } from "./session";
import { fetchSecurePort, secureURL } from "./signaling/secure";

const video = document.querySelector<HTMLVideoElement>("#screen")!;
const status = document.querySelector<HTMLDivElement>("#status")!;
const stats = document.querySelector<HTMLDivElement>("#stats")!;
const controls = document.querySelector<HTMLDivElement>("#controls")!;

let hideTimer: number | undefined;

/** 数秒でフェードアウトさせ、映像以外を画面に残さない（SPEC.md §8.2） */
function show(message: string, autoHide: boolean): void {
  status.replaceChildren(message);
  status.hidden = false;
  controls.hidden = false;
  window.clearTimeout(hideTimer);
  if (autoHide)
    hideTimer = window.setTimeout(() => {
      status.hidden = true;
      controls.hidden = true;
    }, 2500);
}

/** HTTPS 経路へのワンタップ遷移。トークンは fragment のまま引き継ぐ（SPEC.md §5.3） */
async function offerSecureRoute(reason: string): Promise<void> {
  const url = secureURL(location, await fetchSecurePort());
  if (!url) {
    show(reason, false);
    return;
  }
  show(`${reason}\n`, false);
  const link = document.createElement("a");
  link.href = url;
  link.textContent = t.secure.open;
  status.append(link);
}

function describe(state: SessionState): { message: string; autoHide: boolean } {
  switch (state.name) {
    case "connecting":
      return { message: t.status.connecting, autoHide: false };
    case "awaitingApproval":
      return { message: t.status.awaitingApproval, autoHide: false };
    case "negotiating":
      return { message: t.status.negotiating, autoHide: false };
    case "streaming":
      return {
        message: displayName
          ? t.status.connectedTo({ display: displayName })
          : t.status.connected,
        autoHide: true,
      };
    case "reconnecting":
      return { message: t.status.reconnecting, autoHide: false };
    case "closed":
      return {
        message: describeError(state.code, state.detail),
        autoHide: false,
      };
  }
}

let streaming = false;
/** ホストが繋いだかどうか。HTTPS 誘導の判定に使う */
let reachedHost = false;
let displayName = "";

const session = new ViewerSession({
  onState: (state) => {
    streaming = state.name === "streaming";
    if (state.name !== "connecting" && state.name !== "closed")
      reachedHost = true;
    const { message, autoHide } = describe(state);
    show(message, autoHide);
    // 諦めた状態からは人が押して戻せるようにする
    if (state.name === "closed") appendRetry();
    if (streaming) void keepAwake();
  },
  onStream: (stream) => {
    video.srcObject = stream;
    void video.play().catch(() => show(t.status.tapToPlay, false));
  },
  onControl: (message) => {
    switch (message.t) {
      // 画面の名前は映像より少し遅れて届く。届いた時点で言い直す
      // （どの画面を映しているかは、複数の画面を配信できる以上、重要な情報）
      case "hello":
        displayName = message.display.name;
        if (streaming)
          show(t.status.connectedTo({ display: displayName }), true);
        break;
      case "display":
        displayName = message.name;
        if (streaming)
          show(t.status.connectedTo({ display: displayName }), true);
        break;
      case "resume":
      case "stats":
      case "error":
        break;
    }
  },
});

function appendRetry(): void {
  const button = document.createElement("button");
  button.type = "button";
  button.textContent = t.status.retry;
  button.addEventListener("click", () => session.retry());
  status.append(document.createElement("br"), button);
}

// 自己診断は 2 段構え（SPEC.md §5.3）。
// 1. セキュアコンテキストでないと `RTCPeerConnection` を持たないブラウザがある
if (typeof RTCPeerConnection === "undefined") {
  void offerSecureRoute(t.secure.required);
} else {
  session.start();
  reportViewport();
  // 2. ホストへ届いてすらいない場合も HTTPS 側へ誘導する。
  //    判定材料は「シグナリングが繋がったか」だけにする — 繋がった後は
  //    ホストの承認待ちで何分でも止まりうるので、時間では測れない（SPEC.md §5.2）
  window.setTimeout(() => {
    if (!reachedHost) void offerSecureRoute(t.secure.unreachable);
  }, 5000);
}

// MARK: - 解像度追従（SPEC.md §7.1）

/** ホストは表示先の物理ピクセル数に合わせて符号化する。遅延に最も効く経路 */
function reportViewport(): void {
  session.reportViewport(measureViewport(window));
}

window.addEventListener("resize", reportViewport);
document.addEventListener("fullscreenchange", reportViewport);
window.screen.orientation?.addEventListener("change", reportViewport);

// MARK: - 品質プリセット（SPEC.md §7.2）

let quality: QualityPreset = "sharp";
const qualityLabels: Record<QualityPreset, string> = {
  sharp: t.quality.sharp,
  balanced: t.quality.balanced,
  smooth: t.quality.smooth,
};

const qualityButtons = QUALITY_PRESETS.map((preset) => {
  const button = document.createElement("button");
  button.type = "button";
  button.textContent = qualityLabels[preset];
  button.addEventListener("click", (event) => {
    // 映像のタップ（フルスクリーン切替）を巻き込まない
    event.stopPropagation();
    selectQuality(preset);
  });
  controls.append(button);
  return [preset, button] as const;
});

function selectQuality(preset: QualityPreset, announce = true): void {
  quality = preset;
  session.setQuality(preset);
  for (const [name, button] of qualityButtons)
    button.classList.toggle("selected", name === preset);
  if (announce) show(t.quality.changed({ preset: qualityLabels[preset] }), true);
}

// 初期値は選ばれた結果ではないので言わない。接続中の案内を上書きしてしまう
selectQuality(quality, false);

// MARK: - モニタとしての振る舞い

/** 表示中の画面消灯を防ぐ。セキュアコンテキスト限定のため HTTP 経路では効かない（SPEC.md §8.2） */
async function keepAwake(): Promise<void> {
  try {
    await navigator.wakeLock?.request("screen");
  } catch {
    // 取れなくても表示は続ける。案内は出さない（HTTP 経路では取れないのが正常）
  }
}

// フルスクリーンを既定の使用形態にする。ワンタップで入れるようにする（SPEC.md §8.2）
video.addEventListener("click", () => {
  if (document.fullscreenElement) void document.exitFullscreen();
  else void document.documentElement.requestFullscreen().catch(() => {});
});

// 触ったら操作 UI を出す。数秒でまた消える
video.addEventListener("pointermove", () => {
  if (!streaming) return;
  show(
    displayName
      ? t.status.connectedTo({ display: displayName })
      : t.status.connected,
    true,
  );
});

// ページを離れるときは繋ぎ直しを止める。閉じたタブが再接続を試み続けない
window.addEventListener("pagehide", () => session.stop());

// MARK: - 遅延計測オーバーレイ（SPEC.md §3.3）

let previous: Sample | undefined;

window.setInterval(async () => {
  const connection = session.connection;
  if (!connection || !streaming) return;

  const report = await connection.getStats();
  const entries: StatsEntry[] = [];
  report.forEach((entry) => entries.push(entry as StatsEntry));

  const reading = summarize(entries, previous);
  previous = reading.sample;
  stats.textContent = format(reading.latency);
}, 1000);

// 計測は常時見せる必要がない。`s` で消せるようにする
window.addEventListener("keydown", (event) => {
  if (event.key === "s") stats.hidden = !stats.hidden;
});
