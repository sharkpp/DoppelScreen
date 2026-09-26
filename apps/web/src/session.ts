import {
  encodeViewerControl,
  parseHostControl,
  type HostControl,
  type QualityPreset,
  type ViewportMessage,
} from "./control";
import { isFatal } from "./errors";
import { resolveEndpoint, type Endpoint } from "./signaling/endpoint";
import { encodeViewerMessage, parseHostMessage } from "./signaling/messages";

export type SessionState =
  | { name: "connecting" }
  /** ホストの承認待ち（SPEC.md §5.2）。承認されるまでホストは画面を撮らない */
  | { name: "awaitingApproval" }
  | { name: "negotiating" }
  | { name: "streaming" }
  /** 切れたので繋ぎ直しにいく（SPEC.md §11-4） */
  | { name: "reconnecting"; code: string }
  /** 繋ぎ直しても直らない。人が何かしない限り戻らない */
  | { name: "closed"; code: string; detail: string | null };

export type SessionHandlers = {
  onState: (state: SessionState) => void;
  onStream: (stream: MediaStream) => void;
  /** 制御チャネル（SPEC.md §7）からのメッセージ */
  onControl?: (message: HostControl) => void;
};

/** 繋ぎ直しの間隔。刻んで伸ばし、上限で頭打ちにする */
const RETRY_DELAYS_MS = [500, 1000, 2000, 4000, 8000];

/**
 * ホストへ繋ぎ、映像トラックを受け取るまでを受け持つ。
 *
 * ホストが offer を出し、ビューアが answer を返す（SPEC.md §5.1）。ビューアは
 * PeerConnection を offer の到着時に作るため、それより先に届いた ICE candidate は
 * リモート記述が入るまで溜めておく。
 *
 * **切れたら自動で繋ぎ直す**（SPEC.md §11-4）。対象はネットワーク断・スリープ復帰・
 * ディスプレイ構成変更で、いずれも人が操作していない間に起きる。モニタとして使う以上、
 * 戻ってきたときには勝手に映っていなければならない。
 *
 * 繋ぎ直しにはホストが渡す**再接続チケット**を使う。これがないと接続のたびにホストで
 * 承認を押すことになり、自動再接続が意味をなさない。チケットは `sessionStorage` に置く
 * — タブを閉じたら消えるべきもので、端末に残す性質のものではない。
 */
export class ViewerSession {
  private readonly endpoint: Endpoint;
  private readonly handlers: SessionHandlers;
  private readonly resumeKey: string;
  private socket: WebSocket | null = null;
  private peer: RTCPeerConnection | null = null;
  private control: RTCDataChannel | null = null;
  private pendingCandidates: RTCIceCandidateInit[] = [];
  /** 直近に測った表示領域。チャネルが開く前に測った分もここから送る */
  private viewport: ViewportMessage | null = null;
  private quality: QualityPreset | null = null;
  /** 人が閉じた／繋ぎ直しても無駄だと分かった。もう何もしない */
  private stopped = false;
  private attempt = 0;
  private retryTimer: number | undefined;

  constructor(
    handlers: SessionHandlers,
    endpoint: Endpoint = resolveEndpoint(window.location),
  ) {
    this.endpoint = endpoint;
    this.handlers = handlers;
    this.resumeKey = `doppelscreen.resume.${endpoint.display ?? "primary"}`;
  }

  start(): void {
    this.stopped = false;
    this.attempt = 0;
    this.open();
  }

  /** 人が「再接続する」を押したとき。諦めた状態から手動でやり直す */
  retry(): void {
    window.clearTimeout(this.retryTimer);
    this.teardown();
    this.start();
  }

  /** もう繋ぎ直さない。ページを離れるときに呼ぶ */
  stop(): void {
    this.stopped = true;
    window.clearTimeout(this.retryTimer);
    this.teardown();
  }

  /** 遅延計測オーバーレイ用。接続していなければ `null` */
  get connection(): RTCPeerConnection | null {
    return this.peer;
  }

  /**
   * 表示できる領域をホストへ申告する（SPEC.md §7.1）。
   * ホストはこれに合わせて符号化解像度を決めるため、**遅延に最も効く経路**。
   * デバウンスはホスト側が持つので、ここでは変化のたびに素直に送る。
   */
  reportViewport(viewport: ViewportMessage): void {
    this.viewport = viewport;
    this.send(viewport);
  }

  /** 品質プリセットを選ぶ（SPEC.md §7.2）。繋ぎ直したあとも選択を引き継ぐ */
  setQuality(preset: QualityPreset): void {
    this.quality = preset;
    this.send({ t: "quality", preset });
  }

  private send(message: Parameters<typeof encodeViewerControl>[0]): void {
    if (this.control?.readyState !== "open") return;
    this.control.send(encodeViewerControl(message));
  }

  // MARK: - 接続

  private open(): void {
    this.handlers.onState({ name: "connecting" });

    const socket = new WebSocket(this.endpoint.signalUrl);
    this.socket = socket;

    socket.addEventListener("open", () => {
      const resume = sessionStorage.getItem(this.resumeKey);
      this.sendSignal({
        t: "hello",
        token: this.endpoint.token,
        display: this.endpoint.display,
        ...(resume ? { resume } : {}),
      });
      // offer が来るまではホストの承認を待っている（SPEC.md §5.2）
      this.handlers.onState({ name: "awaitingApproval" });
    });
    socket.addEventListener("message", (event) => {
      if (typeof event.data === "string") void this.handleMessage(event.data);
    });
    socket.addEventListener("close", () => {
      if (this.socket !== socket) return;
      this.fail("host_closed");
    });
    socket.addEventListener("error", () => {
      if (this.socket !== socket) return;
      this.fail("connect_failed");
    });
  }

  /**
   * 接続が終わった理由を受けて、繋ぎ直すか諦めるかを決める。
   *
   * トークンが違う・期限切れ・承認されなかった、は繋ぎ直しても同じ結果になる。
   * そこで無限に試すと、ホストのレート制限（SPEC.md §5.1）に自分で引っかかる。
   */
  private fail(code: string, detail: string | null = null): void {
    if (this.stopped) return;
    this.teardown();

    if (isFatal(code)) {
      this.stopped = true;
      // 使えないチケットを持ち越さない
      sessionStorage.removeItem(this.resumeKey);
      this.handlers.onState({ name: "closed", code, detail });
      return;
    }

    const delay =
      RETRY_DELAYS_MS[Math.min(this.attempt, RETRY_DELAYS_MS.length - 1)] ??
      8000;
    this.attempt += 1;
    this.handlers.onState({ name: "reconnecting", code });
    this.retryTimer = window.setTimeout(() => {
      if (!this.stopped) this.open();
    }, delay);
  }

  /** 次の接続に持ち越さないものを落とす。`stopped` は触らない */
  private teardown(): void {
    this.control = null;
    this.pendingCandidates = [];
    const socket = this.socket;
    const peer = this.peer;
    this.socket = null;
    this.peer = null;
    peer?.close();
    socket?.close();
  }

  private async handleMessage(raw: string): Promise<void> {
    const message = parseHostMessage(raw);
    if (!message) return;

    switch (message.t) {
      case "offer":
        await this.acceptOffer(message.sdp);
        break;
      case "candidate":
        await this.addCandidate({
          candidate: message.candidate,
          sdpMid: message.sdpMid,
          sdpMLineIndex: message.sdpMLineIndex,
        });
        break;
      case "error":
        this.fail(message.code, message.detail);
        break;
    }
  }

  private async acceptOffer(sdp: string): Promise<void> {
    this.handlers.onState({ name: "negotiating" });

    // LAN 内直結なので host candidate だけで成立する。STUN / TURN は持たない（SPEC.md §2.1）
    const peer = new RTCPeerConnection({ iceServers: [] });
    this.peer = peer;

    peer.addEventListener("track", (event) => {
      // 遅延削減の最大のレバー。LAN はジッタが小さいのでバッファを捨てる（SPEC.md §3.2）
      // どちらも標準の型定義に無いため、プロパティの有無で判定する
      const receiver = event.receiver as unknown as Record<string, unknown>;
      if ("jitterBufferTarget" in receiver) receiver.jitterBufferTarget = 0;
      else if ("playoutDelayHint" in receiver) receiver.playoutDelayHint = 0; // 旧 Chrome 系

      // SDP の stream ID があっても、ブラウザが渡す streams[0] は空の場合がある。
      // track イベントで渡された映像トラックをそのまま表示対象にする。
      const stream = new MediaStream([event.track]);
      this.handlers.onStream(stream);
      // ここまで来たら繋ぎ直しは成功。次に切れたときは短い間隔から数え直す
      this.attempt = 0;
      this.handlers.onState({ name: "streaming" });
    });

    // 制御チャネルはホストが張る（SPEC.md §7）。開いたら直ちに表示サイズを申告する
    peer.addEventListener("datachannel", (event) => {
      if (event.channel.label !== "control") return;
      this.control = event.channel;
      event.channel.addEventListener("open", () => {
        if (this.viewport) this.reportViewport(this.viewport);
        // 繋ぎ直したときは選んでいた画質を復元する
        if (this.quality) this.setQuality(this.quality);
      });
      event.channel.addEventListener("message", (message: MessageEvent) => {
        if (typeof message.data !== "string") return;
        const parsed = parseHostControl(message.data);
        if (!parsed) return;
        this.absorb(parsed);
        this.handlers.onControl?.(parsed);
      });
    });

    peer.addEventListener("icecandidate", (event) => {
      if (!event.candidate) return;
      this.sendSignal({
        t: "candidate",
        candidate: event.candidate.candidate,
        sdpMid: event.candidate.sdpMid,
        sdpMLineIndex: event.candidate.sdpMLineIndex,
      });
    });

    peer.addEventListener("connectionstatechange", () => {
      if (this.peer !== peer) return;
      if (peer.connectionState === "failed") this.fail("peer_failed");
    });

    await peer.setRemoteDescription({ type: "offer", sdp });
    const answer = await peer.createAnswer();
    await peer.setLocalDescription(answer);
    this.sendSignal({ t: "answer", sdp: answer.sdp ?? "" });

    const queued = this.pendingCandidates;
    this.pendingCandidates = [];
    for (const candidate of queued) await peer.addIceCandidate(candidate);
  }

  /** セッション自身が使う制御メッセージを拾う。UI へはそのまま素通しする */
  private absorb(message: HostControl): void {
    if (message.t === "error") {
      this.fail(message.code, message.detail);
      return;
    }
    if (message.t !== "resume") return;
    // 使い切り。繋ぎ直すたびにホストが新しいものを発行する
    sessionStorage.setItem(this.resumeKey, message.ticket);
  }

  private async addCandidate(candidate: RTCIceCandidateInit): Promise<void> {
    // リモート記述が入る前に渡すと捨てられる。宛先が決まるまで溜める
    if (!this.peer?.remoteDescription) {
      this.pendingCandidates.push(candidate);
      return;
    }
    await this.peer.addIceCandidate(candidate);
  }

  private sendSignal(message: Parameters<typeof encodeViewerMessage>[0]): void {
    if (this.socket?.readyState !== WebSocket.OPEN) return;
    this.socket.send(encodeViewerMessage(message));
  }
}
