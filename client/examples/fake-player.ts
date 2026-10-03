import { SegueClient } from "../src/client.ts";
import { ACTIONS } from "../src/protocol.ts";
import type { Api, Auth, Command, QueueItem, Status } from "../src/protocol.ts";

export type FakePlayerOptions = {
  url: string;
  id: string;
  name: string;
  api: Api;
  auth?: Auth;
};

/** A pretend player for the demo and the tests: no audio, just a queue and a clock that obey commands. */
export class FakePlayer {
  readonly client: SegueClient;
  status: Status = "stopped";
  queue: QueueItem[] = [];
  index = 0;
  volume = 100;
  #positionMs = 0;
  #since = Date.now(); // local time at which #positionMs held

  constructor(opts: FakePlayerOptions) {
    this.client = new SegueClient({
      url: opts.url,
      auth: opts.auth ?? { scheme: "subsonic", username: "dev", token: "-", salt: "-" },
      device: {
        id: opts.id, name: opts.name, client: "FakePlayer", api: opts.api,
        roles: ["player", "controller"], capabilities: [...ACTIONS],
      },
      onCommand: (command) => this.#obey(command),
    });
  }

  get positionMs(): number {
    return this.status === "playing" ? this.#positionMs + (Date.now() - this.#since) : this.#positionMs;
  }

  connect(): Promise<void> {
    return this.client.connect();
  }

  /** What the user does on this device: starts a queue. */
  play(queue: QueueItem[], index = 0, positionMs = 0): void {
    this.queue = queue;
    this.index = index;
    this.#seek(positionMs);
    this.#setStatus("playing");
    this.report();
  }

  report(): void {
    this.client.sendState({
      status: this.status, positionMs: this.positionMs, queue: this.queue, index: this.index, volume: this.volume,
    });
  }

  #obey(command: Command): void {
    switch (command.action) {
      case "play":
        this.#setStatus("playing");
        break;
      case "pause":
        this.#setStatus("paused");
        break;
      case "toggle":
        this.#setStatus(this.status === "playing" ? "paused" : "playing");
        break;
      case "stop":
        this.#setStatus("stopped");
        this.#seek(0);
        break;
      case "next":
      case "previous":
        this.#jump(this.index + (command.action === "next" ? 1 : -1));
        break;
      case "seek":
        this.#seek(command.positionMs);
        break;
      case "setVolume":
        this.volume = command.volume;
        break;
      case "setQueue":
        this.queue = command.queue;
        this.index = command.index;
        this.#seek(command.positionMs);
        this.#setStatus(command.play ? "playing" : "paused");
        break;
    }
    this.report();
  }

  #setStatus(status: Status): void {
    this.#seek(this.positionMs);
    this.status = status;
  }

  #seek(positionMs: number): void {
    this.#positionMs = positionMs;
    this.#since = Date.now();
  }

  #jump(index: number): void {
    if (index < 0 || index >= this.queue.length) throw new Error("no such track");
    this.index = index;
    this.#seek(0);
  }
}
