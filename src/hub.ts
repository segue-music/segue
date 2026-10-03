import { randomUUID } from "node:crypto";
import type { Authenticator } from "./auth.ts";
import { noTranslation, type IdTranslator } from "./ids.ts";
import {
  CloseCode, PROTOCOL_VERSION, currentPositionMs, parseAuth, parseCommand, parseDeviceInfo, parsePlayerState,
} from "./protocol.ts";
import type { Api, Command, Device, DeviceInfo, HubMessage, QueueItem, StampedState } from "./protocol.ts";

/** The hub's view of a transport connection: a WebSocket in server.ts. */
export type Conn = {
  send(msg: HubMessage): void;
  close(code: number, reason: string): void;
};

/** What the transport feeds the hub for one connection. */
export type Session = {
  message(raw: string): void;
  closed(): void;
};

export type HubOptions = {
  authenticate: Authenticator;
  translate?: IdTranslator;
  now?: () => number;
  log?: (line: string) => void;
  /** How long to wait for the first message (the hello). */
  helloTimeoutMs?: number;
  /** How long to wait for a player to answer a command. */
  commandTimeoutMs?: number;
  /** How long an offline device, with its last state, stays listed. */
  offlineTtlMs?: number;
};

type Entry = { user: string; info: DeviceInfo; conn?: Conn; state?: StampedState; lastSeen: number };
type Outcome = { ok: boolean; error?: string };
type Pending = { target: Entry; finish: (outcome: Outcome) => void };
type Obj = Record<string, unknown>;

/**
 * Keeps the live devices of each user, relays their state to the user's other devices and routes
 * commands between them. Holds nothing on disk: a restart only makes the devices reconnect.
 */
export class Hub {
  #authenticate: Authenticator;
  #translate: IdTranslator;
  #now: () => number;
  #log: (line: string) => void;
  #helloTimeoutMs: number;
  #commandTimeoutMs: number;
  #offlineTtlMs: number;
  #users = new Map<string, Map<string, Entry>>();
  #pending = new Map<string, Pending>();

  constructor(opts: HubOptions) {
    this.#authenticate = opts.authenticate;
    this.#translate = opts.translate ?? noTranslation;
    this.#now = opts.now ?? Date.now;
    this.#log = opts.log ?? (() => {});
    this.#helloTimeoutMs = opts.helloTimeoutMs ?? 10_000;
    this.#commandTimeoutMs = opts.commandTimeoutMs ?? 10_000;
    this.#offlineTtlMs = opts.offlineTtlMs ?? 24 * 3_600_000;
  }

  open(conn: Conn): Session {
    let entry: Entry | undefined;
    let greeted = false;
    let closed = false;
    const helloTimer = setTimeout(() => conn.close(CloseCode.badHello, "no hello"), this.#helloTimeoutMs);
    return {
      message: (raw) => {
        let msg: unknown;
        try {
          msg = JSON.parse(raw);
        } catch {
          msg = undefined;
        }
        if (typeof msg !== "object" || msg === null || Array.isArray(msg)) {
          conn.send({ type: "error", error: "badMessage" });
          return;
        }
        const obj = msg as Obj;
        if (!greeted) {
          greeted = true;
          clearTimeout(helloTimer);
          this.#hello(conn, obj, () => closed).then(
            (e) => (entry = e),
            (err) => {
              this.#log(`hello failed: ${err instanceof Error ? err.stack : err}`);
              conn.close(1011, "internal error");
            },
          );
        } else if (!entry) {
          conn.send({ type: "error", error: "notReady" });
        } else if (entry.conn === conn) {
          this.#dispatch(entry, conn, obj);
        }
      },
      closed: () => {
        closed = true;
        clearTimeout(helloTimer);
        if (entry?.conn === conn) this.#disconnect(entry);
      },
    };
  }

  /** Drops offline devices not seen for longer than the TTL. */
  sweep(): void {
    const cutoff = this.#now() - this.#offlineTtlMs;
    for (const [user, devices] of this.#users) {
      for (const entry of devices.values()) {
        if (entry.conn || entry.lastSeen >= cutoff) continue;
        devices.delete(entry.info.id);
        this.#broadcast(entry, () => ({ type: "gone", deviceId: entry.info.id }));
      }
      if (devices.size === 0) this.#users.delete(user);
    }
  }

  async #hello(conn: Conn, msg: Obj, isClosed: () => boolean): Promise<Entry | undefined> {
    if (msg.type !== "hello" || msg.protocol !== PROTOCOL_VERSION) {
      conn.close(CloseCode.badHello, `expected a hello for protocol ${PROTOCOL_VERSION}`);
      return undefined;
    }
    const auth = parseAuth(msg.auth);
    const info = parseDeviceInfo(msg.device);
    if (!auth || !info) {
      conn.close(CloseCode.badHello, "malformed hello");
      return undefined;
    }
    let user: string | undefined;
    try {
      user = await this.#authenticate(auth);
    } catch (err) {
      this.#log(`media server unreachable: ${err instanceof Error ? err.message : err}`);
      if (!isClosed()) conn.close(1011, "media server unreachable");
      return undefined;
    }
    if (isClosed()) return undefined;
    if (user === undefined) {
      this.#log(`${info.name} (${info.client}): credentials rejected`);
      conn.close(CloseCode.unauthorized, "credentials rejected by the media server");
      return undefined;
    }

    const devices = this.#devicesOf(user);
    let entry = devices.get(info.id);
    const replaced = entry?.conn;
    if (entry) Object.assign(entry, { info, conn, lastSeen: this.#now() });
    else devices.set(info.id, (entry = { user: user.toLowerCase(), info, conn, lastSeen: this.#now() }));
    if (replaced) {
      this.#failPending(entry, "offline");
      replaced.close(CloseCode.replaced, "the device connected again");
    }

    const others = [...devices.values()].filter((e) => e !== entry).map((e) => this.#view(e, info.api));
    conn.send({ type: "welcome", protocol: PROTOCOL_VERSION, user, serverTime: this.#now(), devices: others });
    this.#announce(entry);
    this.#log(`${user}: ${info.name} (${info.client}) connected`);
    return entry;
  }

  #disconnect(entry: Entry): void {
    entry.conn = undefined;
    entry.lastSeen = this.#now();
    this.#failPending(entry, "offline");
    this.#announce(entry);
    this.#log(`${entry.user}: ${entry.info.name} disconnected`);
  }

  #dispatch(entry: Entry, conn: Conn, msg: Obj): void {
    switch (msg.type) {
      case "state":
        return this.#onState(entry, conn, msg);
      case "command":
        return void this.#onCommand(entry, conn, msg);
      case "transfer":
        return void this.#onTransfer(entry, conn, msg);
      case "result":
        return this.#onResult(entry, msg);
    }
    conn.send({ type: "error", error: "badMessage" });
  }

  #onState(entry: Entry, conn: Conn, msg: Obj): void {
    if (!entry.info.roles.includes("player")) return conn.send({ type: "error", error: "notPlayer" });
    const report = parsePlayerState(msg.state);
    if (!report) return conn.send({ type: "error", error: "badMessage" });
    const at = this.#now();
    entry.state = { ...entry.state, ...report, at };
    entry.lastSeen = at;
    // Recipients merge the report into what they have, so relay only what the player sent.
    this.#broadcast(entry, (to) => ({
      type: "state", deviceId: entry.info.id, state: this.#translateState({ ...report, at }, entry.info.api, to.info.api),
    }));
  }

  async #onCommand(entry: Entry, conn: Conn, msg: Obj): Promise<void> {
    if (typeof msg.id !== "string") return conn.send({ type: "error", error: "badMessage" });
    const command = parseCommand(msg.command);
    const target = typeof msg.target === "string" ? this.#devicesOf(entry.user).get(msg.target) : undefined;
    const outcome: Outcome = !command ? { ok: false, error: "badMessage" }
      : !target ? { ok: false, error: "unknownDevice" }
      : await this.#request(target, command, entry.info.api, entry.info.id);
    conn.send({ type: "result", re: msg.id, ...outcome });
  }

  /** Hands the source's queue, at its current position, to the destination; then pauses the source. */
  async #onTransfer(entry: Entry, conn: Conn, msg: Obj): Promise<void> {
    const { id } = msg;
    if (typeof id !== "string") return conn.send({ type: "error", error: "badMessage" });
    const reply = (outcome: Outcome) => conn.send({ type: "result", re: id, ...outcome });
    const devices = this.#devicesOf(entry.user);
    const source = typeof msg.from === "string" ? devices.get(msg.from) : undefined;
    const destination = typeof msg.to === "string" ? devices.get(msg.to) : undefined;
    if (!source || !destination) return reply({ ok: false, error: "unknownDevice" });
    if (source === destination || (msg.play !== undefined && typeof msg.play !== "boolean")) {
      return reply({ ok: false, error: "badMessage" });
    }
    // An offline source still has its last state: the queue of a closed app can be picked up.
    const state = source.state;
    if (!state?.queue?.length) return reply({ ok: false, error: "nothingToTransfer" });
    const handoff: Command = {
      action: "setQueue", queue: state.queue, index: state.index ?? 0,
      positionMs: currentPositionMs(state, this.#now()), play: msg.play !== false,
    };
    const outcome = await this.#request(destination, handoff, source.info.api, entry.info.id);
    if (outcome.ok && source.conn && source.state?.status === "playing") {
      // Best effort: the music has already moved, so a source that won't pause doesn't undo it.
      await this.#request(source, { action: "pause" }, source.info.api, entry.info.id);
    }
    reply(outcome);
  }

  #onResult(entry: Entry, msg: Obj): void {
    const pending = typeof msg.re === "string" ? this.#pending.get(msg.re) : undefined;
    if (!pending || pending.target !== entry) return; // late, or not this device's to answer
    pending.finish(msg.ok === true ? { ok: true } : { ok: false, error: typeof msg.error === "string" ? msg.error : "failed" });
  }

  /** Sends a command to a player and waits for its answer. `fromApi` is the id space of any queue in it. */
  #request(target: Entry, command: Command, fromApi: Api, from: string): Promise<Outcome> {
    const conn = target.conn;
    if (!conn) return Promise.resolve({ ok: false, error: "offline" });
    if (!target.info.roles.includes("player")) return Promise.resolve({ ok: false, error: "notPlayer" });
    if (!target.info.capabilities.includes(command.action)) return Promise.resolve({ ok: false, error: "unsupported" });
    const sent = command.action === "setQueue"
      ? { ...command, queue: this.#translateQueue(command.queue, fromApi, target.info.api) }
      : command;
    const id = randomUUID();
    return new Promise((resolve) => {
      const timer = setTimeout(() => finish({ ok: false, error: "timeout" }), this.#commandTimeoutMs);
      const finish = (outcome: Outcome) => {
        clearTimeout(timer);
        this.#pending.delete(id);
        resolve(outcome);
      };
      this.#pending.set(id, { target, finish });
      conn.send({ type: "command", id, from, command: sent });
    });
  }

  #failPending(entry: Entry, error: string): void {
    for (const pending of [...this.#pending.values()]) if (pending.target === entry) pending.finish({ ok: false, error });
  }

  #devicesOf(user: string): Map<string, Entry> {
    const key = user.toLowerCase();
    let devices = this.#users.get(key);
    if (!devices) this.#users.set(key, (devices = new Map()));
    return devices;
  }

  /** Tells the device's siblings about its info and presence (and its full state). */
  #announce(entry: Entry): void {
    this.#broadcast(entry, (to) => ({ type: "device", device: this.#view(entry, to.info.api) }));
  }

  /** Sends to every other connected device of the same user, built for each recipient's API. */
  #broadcast(source: Entry, build: (to: Entry) => HubMessage): void {
    for (const to of this.#devicesOf(source.user).values()) if (to !== source && to.conn) to.conn.send(build(to));
  }

  #view(entry: Entry, api: Api): Device {
    const device: Device = { ...entry.info, online: entry.conn !== undefined };
    if (entry.state) device.state = this.#translateState(entry.state, entry.info.api, api);
    return device;
  }

  #translateState<S extends { queue?: QueueItem[] }>(state: S, from: Api, to: Api): S {
    return state.queue && from !== to ? { ...state, queue: this.#translateQueue(state.queue, from, to) } : state;
  }

  #translateQueue(queue: QueueItem[], from: Api, to: Api): QueueItem[] {
    if (from === to) return queue;
    return queue.map(({ id, ...item }) => {
      const translated = id === undefined ? undefined : this.#translate(id, from, to);
      return translated === undefined ? item : { id: translated, ...item };
    });
  }
}
