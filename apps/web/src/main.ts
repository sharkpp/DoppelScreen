import "./style.css";
import { ViewerSession, type SessionState } from "./session";

const video = document.querySelector<HTMLVideoElement>("#screen")!;
const status = document.querySelector<HTMLDivElement>("#status")!;

let hideTimer: number | undefined;

/** 数秒でフェードアウトさせ、映像以外を画面に残さない（SPEC.md §8.2） */
function show(message: string, autoHide: boolean): void {
  status.textContent = message;
  status.hidden = false;
  window.clearTimeout(hideTimer);
  if (autoHide)
    hideTimer = window.setTimeout(() => (status.hidden = true), 2500);
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

const session = new ViewerSession({
  onState: (state) => {
    const { message, autoHide } = describe(state);
    show(message, autoHide);
  },
  onStream: (stream) => {
    video.srcObject = stream;
    void video
      .play()
      .catch(() => show("画面をタップして再生してください", false));
  },
});

// セキュアコンテキストでないと `RTCPeerConnection` を持たないブラウザがある（SPEC.md §5.3）。
// HTTPS 経路への誘導はステップ 7 で追加する。
if (typeof RTCPeerConnection === "undefined") {
  show(
    "このブラウザでは WebRTC を利用できません（HTTPS 経路が必要です）",
    false,
  );
} else {
  session.start();
}

// フルスクリーンを既定の使用形態にする。ワンタップで入れるようにする（SPEC.md §8.2）
video.addEventListener("click", () => {
  if (document.fullscreenElement) void document.exitFullscreen();
  else void document.documentElement.requestFullscreen().catch(() => {});
});
