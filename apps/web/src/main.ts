import "./style.css";
import { format, summarize, type Sample, type StatsEntry } from "./latency";
import { ViewerSession, type SessionState } from "./session";
import { fetchSecurePort, secureURL } from "./signaling/secure";

const video = document.querySelector<HTMLVideoElement>("#screen")!;
const status = document.querySelector<HTMLDivElement>("#status")!;
const stats = document.querySelector<HTMLDivElement>("#stats")!;

let hideTimer: number | undefined;

/** 数秒でフェードアウトさせ、映像以外を画面に残さない（SPEC.md §8.2） */
function show(message: string, autoHide: boolean): void {
  status.textContent = message;
  status.hidden = false;
  window.clearTimeout(hideTimer);
  if (autoHide)
    hideTimer = window.setTimeout(() => (status.hidden = true), 2500);
}

/** HTTPS 経路へのワンタップ遷移。トークンは fragment のまま引き継ぐ（SPEC.md §5.3） */
async function offerSecureRoute(reason: string): Promise<void> {
  const url = secureURL(location, await fetchSecurePort());
  if (!url) {
    show(reason, false);
    return;
  }
  status.hidden = false;
  status.textContent = `${reason}\n`;
  const link = document.createElement("a");
  link.href = url;
  link.textContent = "HTTPS で開き直す";
  status.append(link);
}

function describe(state: SessionState): { message: string; autoHide: boolean } {
  switch (state.name) {
    case "connecting":
      return { message: "ホストへ接続しています…", autoHide: false };
    case "negotiating":
      return { message: "映像を準備しています…", autoHide: false };
    case "streaming":
      return { message: "接続しました", autoHide: true };
    case "closed":
      return { message: state.reason, autoHide: false };
  }
}

let streaming = false;

const session = new ViewerSession({
  onState: (state) => {
    streaming = state.name === "streaming";
    const { message, autoHide } = describe(state);
    show(message, autoHide);
    if (streaming) void keepAwake();
  },
  onStream: (stream) => {
    video.srcObject = stream;
    void video
      .play()
      .catch(() => show("画面をタップして再生してください", false));
  },
});

// 自己診断は 2 段構え（SPEC.md §5.3）。
// 1. セキュアコンテキストでないと `RTCPeerConnection` を持たないブラウザがある
if (typeof RTCPeerConnection === "undefined") {
  void offerSecureRoute(
    "このブラウザは WebRTC にセキュアな接続を必要とします。",
  );
} else {
  session.start();
  // 2. 生成はできたが 5 秒で確立しない場合も HTTPS 側へ誘導する
  window.setTimeout(() => {
    if (!streaming) void offerSecureRoute("接続できません。");
  }, 5000);
}

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
