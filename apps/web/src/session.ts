import {
  encodeViewerControl,
  parseHostControl,
  type HostControl,
  type ViewerControl,
} from "./control";
import { resolveEndpoint, type Endpoint } from "./signaling/endpoint";
import { encodeViewerMessage, parseHostMessage } from "./signaling/messages";

export type SessionState =
  | { name: "connecting" }
  /** ホストの承認待ち（SPEC.md §5.2）。承認されるまでホストは画面を撮らない */
  | { name: "awaitingApproval" }
  | { name: "negotiating" }
  | { name: "streaming" }
  | { name: "closed"; reason: string };

export type SessionHandlers = {
  onState: (state: SessionState) => void;
  onStream: (stream: MediaStream) => void;
  /** 制御チャネル（SPEC.md §7）からのメッセージ */
  onControl?: (message: HostControl) => void;
};

/**
 * ホストへ繋ぎ、映像トラックを受け取るまでを受け持つ。
 *
 * ホストが offer を出し、ビューアが answer を返す（SPEC.md §5.1）。ビューアは
 * PeerConnection を offer の到着時に作るため、それより先に届いた ICE candidate は
 * リモート記述が入るまで溜めておく。
 */
export class ViewerSession {
  private readonly endpoint: Endpoint;
  private readonly handlers: SessionHandlers;
  private socket: WebSocket | null = null;
  private peer: RTCPeerConnection | null = null;
  private control: RTCDataChannel | null = null;
  private pendingCandidates: RTCIceCandidateInit[] = [];
  /** 直近に測った表示領域。チャネルが開く前に測った分もここから送る */
  private viewport: ViewerControl | null = null;
  private closed = false;

  constructor(
    handlers: SessionHandlers,
    endpoint: Endpoint = resolveEndpoint(window.location),
  ) {
    this.endpoint = endpoint;
    this.handlers = handlers;
  }

  start(): void {
    this.handlers.onState({ name: "connecting" });

    const socket = new WebSocket(this.endpoint.signalUrl);
    this.socket = socket;

    socket.addEventListener("open", () => {
      this.send({
        t: "hello",
        token: this.endpoint.token,
        display: this.endpoint.display,
      });
      // offer が来るまではホストの承認を待っている（SPEC.md §5.2）
      this.handlers.onState({ name: "awaitingApproval" });
    });
    socket.addEventListener("message", (event) => {
      if (typeof event.data === "string") void this.handleMessage(event.data);
    });
    socket.addEventListener("close", () => {
      this.close("ホストとの接続が切れました");
    });
    socket.addEventListener("error", () => {
      this.close("ホストへ接続できませんでした");
    });
  }

  close(reason: string): void {
    if (this.closed) return;
    this.closed = true;
    this.control = null;
    this.peer?.close();
    this.peer = null;
    this.socket?.close();
    this.socket = null;
    this.handlers.onState({ name: "closed", reason });
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
  reportViewport(viewport: ViewerControl): void {
    this.viewport = viewport;
    if (this.control?.readyState !== "open") return;
    this.control.send(encodeViewerControl(viewport));
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
        this.close(message.message);
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

      const stream = event.streams[0] ?? new MediaStream([event.track]);
      this.handlers.onStream(stream);
      this.handlers.onState({ name: "streaming" });
    });

    // 制御チャネルはホストが張る（SPEC.md §7）。開いたら直ちに表示サイズを申告する
    peer.addEventListener("datachannel", (event) => {
      if (event.channel.label !== "control") return;
      this.control = event.channel;
      event.channel.addEventListener("open", () => {
        if (this.viewport) this.reportViewport(this.viewport);
      });
      event.channel.addEventListener("message", (message: MessageEvent) => {
        if (typeof message.data !== "string") return;
        const parsed = parseHostControl(message.data);
        if (parsed) this.handlers.onControl?.(parsed);
      });
    });

    peer.addEventListener("icecandidate", (event) => {
      if (!event.candidate) return;
      this.send({
        t: "candidate",
        candidate: event.candidate.candidate,
        sdpMid: event.candidate.sdpMid,
        sdpMLineIndex: event.candidate.sdpMLineIndex,
      });
    });

    peer.addEventListener("connectionstatechange", () => {
      if (peer.connectionState === "failed") this.close("接続に失敗しました");
    });

    await peer.setRemoteDescription({ type: "offer", sdp });
    const answer = await peer.createAnswer();
    await peer.setLocalDescription(answer);
    this.send({ t: "answer", sdp: answer.sdp ?? "" });

    const queued = this.pendingCandidates;
    this.pendingCandidates = [];
    for (const candidate of queued) await peer.addIceCandidate(candidate);
  }

  private async addCandidate(candidate: RTCIceCandidateInit): Promise<void> {
    // リモート記述が入る前に渡すと捨てられる。宛先が決まるまで溜める
    if (!this.peer?.remoteDescription) {
      this.pendingCandidates.push(candidate);
      return;
    }
    await this.peer.addIceCandidate(candidate);
  }

  private send(message: Parameters<typeof encodeViewerMessage>[0]): void {
    if (this.socket?.readyState !== WebSocket.OPEN) return;
    this.socket.send(encodeViewerMessage(message));
  }
}
