import { PROTOCOL_VERSION, currentPositionMs } from "./protocol.ts";
import type {
  Auth, ClientMessage, Command, CommandRequest, Device, DeviceInfo, HubMessage, LastPlayback, PlayerState, Result,
  TransferRequest,
} from "./protocol.ts";

export type ClientOptions = {
  /** The hub's WebSocket URL, e.g. wss://music.example.org/connect/v1/ws. */
  url: string;
  auth: Auth;
  device: DeviceInfo;
  /** Obeys a command from another device. Throwing (or rejecting) reports it as failed. */
  onCommand?: (command: Command, from: string) => void | Promise<void>;
  /** Called after every change to `devices`. */
  onChange?: () => void;
};

/**
 * Reference client for one device: keeps the user's other devices up to date and talks to the hub.
 * Uses only the standard WebSocket API, so the same code runs in browsers, Node and React Native.
 */
export class SegueClient {
  /** The user's other devices, by id. */
  readonly devices = new Map<string, Device>();
  /** The user's last playback, as of the last welcome. */
  lastPlayback?: LastPlayback;
  #opts: ClientOptions;
  #ws?: WebSocket;
  #seq = 0;
  #waiting = new Map<string, (result: Result) => void>();
  #clockOffset = 0; // hub time minus local time

  constructor(opts: ClientOptions) {
    this.#opts = opts;
  }

  /** Connects and resolves once the hub has accepted the device. */
  connect(): Promise<void> {
    return new Promise((resolve, reject) => {
      const ws = new WebSocket(this.#opts.url);
      this.#ws = ws;
      let welcomed = false;
      ws.addEventListener("open", () => {
        this.#send({ type: "hello", protocol: PROTOCOL_VERSION, auth: this.#opts.auth, device: this.#opts.device });
      });
      ws.addEventListener("message", (event) => {
        const msg = JSON.parse(String(event.data)) as HubMessage;
        this.#receive(msg);
        if (msg.type === "welcome") {
          welcomed = true;
          resolve();
        }
      });
      ws.addEventListener("close", (event) => {
        for (const [re, done] of this.#waiting) done({ type: "result", re, ok: false, error: "closed" });
        this.#waiting.clear();
        if (!welcomed) reject(Object.assign(new Error(`hub closed the connection: ${event.reason}`), { code: event.code }));
      });
    });
  }

  close(): void {
    this.#ws?.close(1000);
  }

  /** Reports this device's playback. Send it on every change; the hub stamps the time. */
  sendState(state: PlayerState): void {
    this.#send({ type: "state", state });
  }

  command(target: string, command: Command): Promise<Result> {
    return this.#ask({ type: "command", id: this.#nextId(), target, command });
  }

  /** Moves `from`'s queue, at its current position, to `to` (often this device: "continue here"). */
  transfer(from: string, to: string, play = true): Promise<Result> {
    return this.#ask({ type: "transfer", id: this.#nextId(), from, to, play });
  }

  /** Where a device's playback is now, by the hub's clock. */
  positionMs(deviceId: string): number | undefined {
    const state = this.devices.get(deviceId)?.state;
    return state && currentPositionMs(state, Date.now() + this.#clockOffset);
  }

  #receive(msg: HubMessage): void {
    switch (msg.type) {
      case "welcome":
        this.#clockOffset = msg.serverTime - Date.now();
        this.lastPlayback = msg.lastPlayback;
        this.devices.clear();
        for (const device of msg.devices) this.devices.set(device.id, device);
        break;
      case "device":
        this.devices.set(msg.device.id, msg.device);
        break;
      case "state": {
        const device = this.devices.get(msg.deviceId);
        if (device) device.state = { ...device.state, ...msg.state };
        break;
      }
      case "gone":
        this.devices.delete(msg.deviceId);
        break;
      case "command":
        void this.#obey(msg.id, msg.command, msg.from);
        return;
      case "result":
        this.#waiting.get(msg.re)?.(msg);
        this.#waiting.delete(msg.re);
        return;
      case "error":
        return;
    }
    this.#opts.onChange?.();
  }

  async #obey(re: string, command: Command, from: string): Promise<void> {
    try {
      if (!this.#opts.onCommand) throw new Error("unsupported");
      await this.#opts.onCommand(command, from);
      this.#send({ type: "result", re, ok: true });
    } catch (err) {
      this.#send({ type: "result", re, ok: false, error: err instanceof Error ? err.message : String(err) });
    }
  }

  #ask(msg: CommandRequest | TransferRequest): Promise<Result> {
    if (this.#ws?.readyState !== WebSocket.OPEN) {
      return Promise.resolve({ type: "result", re: msg.id, ok: false, error: "closed" });
    }
    return new Promise((resolve) => {
      this.#waiting.set(msg.id, resolve);
      this.#send(msg);
    });
  }

  #nextId(): string {
    return `r${++this.#seq}`;
  }

  #send(msg: ClientMessage): void {
    if (this.#ws?.readyState === WebSocket.OPEN) this.#ws.send(JSON.stringify(msg));
  }
}
