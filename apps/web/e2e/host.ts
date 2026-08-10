import { spawn } from "node:child_process";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const APP = resolve(
  import.meta.dirname,
  "../../macos/build/Build/Products/Debug/DoppelScreen.app",
);

export type Handshake = {
  port: number;
  securePort?: number;
  token: string;
  urls: string[];
  secureUrls: string[];
};
export type Report = {
  ok: boolean;
  error?: string;
  serve?: {
    viewerConnected: boolean;
    viewerState: string;
    iceConnectionState: string;
    codec?: string;
    encoderImplementation?: string;
    framesSent: number;
    frameWidth: number;
    frameHeight: number;
    capturedWidth: number;
    capturedHeight: number;
    framesEncoded: number;
    keyFramesEncoded: number;
    encodeMs: number;
    packetSendMs: number;
    targetBitrateMbps: number;
    qualityLimitationReason: string;
    candidatePairs: string[];
  };
};

/**
 * ホストを検証モード（`--selftest --serve`）で起動する。
 *
 * `open` で起動する。実行ファイルを直接叩くと TCC が「責任プロセス」として
 * ターミナルの許諾を参照し、画面収録の可否が実態と食い違う（docs/STACK.md §2.7）。
 */
export class Host {
  private directory!: string;

  async start(durationSeconds: number): Promise<Handshake> {
    this.directory = await mkdtemp(join(tmpdir(), "doppelscreen-e2e-"));

    const child = spawn("open", [
      "-n",
      "-a",
      APP,
      "--args",
      "--selftest",
      "--serve",
      "--output",
      this.directory,
      "--duration",
      String(durationSeconds),
    ]);
    await new Promise<void>((done, fail) => {
      child.on("exit", (code) =>
        code === 0 ? done() : fail(new Error(`open が ${code} で終了しました`)),
      );
    });

    // 検証モードは NSApplication を起動しないので `open -W` で待てない。
    // 待受開始の合図としてホストが書く serve.json を待つ
    return await this.readJSON<Handshake>("serve.json", 30_000);
  }

  /** ホスト側の最終レポート。ビューアへ実際にフレームが出たかはここで判定する */
  async report(timeoutMs: number): Promise<Report> {
    return await this.readJSON<Report>("report.json", timeoutMs);
  }

  async cleanup(): Promise<void> {
    await rm(this.directory, { recursive: true, force: true });
  }

  private async readJSON<T>(name: string, timeoutMs: number): Promise<T> {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      try {
        return JSON.parse(
          await readFile(join(this.directory, name), "utf8"),
        ) as T;
      } catch {
        await new Promise((done) => setTimeout(done, 250));
      }
    }
    throw new Error(`${name} が ${timeoutMs}ms 以内に現れませんでした`);
  }
}
