// Wire format of the Segue protocol, version 1 (draft). SPEC.md explains the semantics; this file
// is the reference for message names and shapes, shared by the hub and the reference client.

export const PROTOCOL_VERSION = 1;

/** The media server API a device speaks. Item ids in its messages belong to that API. */
export type Api = "subsonic" | "jellyfin";
export type Role = "player" | "controller";
export type Status = "playing" | "paused" | "stopped";

/** The credentials the device already uses with the media server. The hub checks them there. */
export type Auth =
  | { scheme: "subsonic"; username: string; token: string; salt: string }
  | { scheme: "apiKey"; apiKey: string }
  | { scheme: "jellyfin"; token: string };

export type QueueItem = {
  /** The media server's id, in the recipient's API. Absent when the hub couldn't translate it. */
  id?: string;
  title?: string;
  artist?: string;
  album?: string;
  durationMs?: number;
};

/**
 * What a player reports. `status` and `positionMs` go in every report, since together they define
 * the playback clock. An optional field left out keeps its previous value.
 */
export type PlayerState = {
  status: Status;
  positionMs: number;
  queue?: QueueItem[];
  index?: number;
  volume?: number;
};

/** A state as relayed by the hub. `at` is the hub time (epoch ms) at which `positionMs` held. */
export type StampedState = PlayerState & { at: number };

export type Command =
  | { action: "play" | "pause" | "toggle" | "stop" | "next" | "previous" }
  | { action: "seek"; positionMs: number }
  | { action: "setVolume"; volume: number }
  | { action: "setQueue"; queue: QueueItem[]; index: number; positionMs: number; play: boolean };

export type Action = Command["action"];

export const ACTIONS: readonly Action[] = [
  "play", "pause", "toggle", "stop", "next", "previous", "seek", "setVolume", "setQueue",
];

export type DeviceInfo = {
  /** Stable per installation (a UUID the app keeps), not per connection. */
  id: string;
  name: string;
  client: string;
  version?: string;
  api: Api;
  roles: Role[];
  /** The commands this device obeys as a player. */
  capabilities: Action[];
};

export type Device = DeviceInfo & { online: boolean; state?: StampedState };

// Device → hub.
export type Hello = { type: "hello"; protocol: number; auth: Auth; device: DeviceInfo };
export type StateReport = { type: "state"; state: PlayerState };
export type CommandRequest = { type: "command"; id: string; target: string; command: Command };
export type TransferRequest = { type: "transfer"; id: string; from: string; to: string; play?: boolean };
/** Answers a request: a player answering the hub's command, or the hub answering a device. */
export type Result = { type: "result"; re: string; ok: boolean; error?: string };

export type ClientMessage = Hello | StateReport | CommandRequest | TransferRequest | Result;

// Hub → device.
export type Welcome = { type: "welcome"; protocol: number; user: string; serverTime: number; devices: Device[] };
export type DeviceEvent = { type: "device"; device: Device };
export type StateEvent = { type: "state"; deviceId: string; state: StampedState };
export type GoneEvent = { type: "gone"; deviceId: string };
export type CommandEvent = { type: "command"; id: string; from: string; command: Command };
export type ErrorEvent = { type: "error"; error: string };

export type HubMessage = Welcome | DeviceEvent | StateEvent | GoneEvent | CommandEvent | Result | ErrorEvent;

export const CloseCode = {
  /** The media server rejected the credentials. */
  unauthorized: 4001,
  /** The first message wasn't a valid hello for a protocol version the hub speaks. */
  badHello: 4002,
  /** The same device connected again; the old connection is dropped. */
  replaced: 4003,
} as const;

/** Where playback is now, extrapolated from the last report. */
export function currentPositionMs(state: StampedState, now: number): number {
  if (state.status !== "playing") return state.positionMs;
  const position = state.positionMs + Math.max(0, now - state.at);
  const duration = state.queue?.[state.index ?? 0]?.durationMs;
  return duration === undefined ? position : Math.min(position, duration);
}

// Parsers for what arrives from the network: each returns a clean copy, or undefined if malformed.

type Obj = Record<string, unknown>;
const isObj = (v: unknown): v is Obj => typeof v === "object" && v !== null && !Array.isArray(v);
const isText = (v: unknown): v is string => typeof v === "string" && v.length > 0;
const isMs = (v: unknown): v is number => typeof v === "number" && Number.isFinite(v) && v >= 0;
const isIndex = (v: unknown): v is number => Number.isInteger(v) && (v as number) >= 0;
const isVolume = (v: unknown): v is number => isMs(v) && v <= 100;
const optional = <T>(v: unknown, check: (v: unknown) => v is T): v is T | undefined =>
  v === undefined || check(v);
const actionSet: ReadonlySet<unknown> = new Set(ACTIONS);

export function parseAuth(v: unknown): Auth | undefined {
  if (!isObj(v)) return undefined;
  switch (v.scheme) {
    case "subsonic":
      return isText(v.username) && isText(v.token) && isText(v.salt)
        ? { scheme: "subsonic", username: v.username, token: v.token, salt: v.salt }
        : undefined;
    case "apiKey":
      return isText(v.apiKey) ? { scheme: "apiKey", apiKey: v.apiKey } : undefined;
    case "jellyfin":
      return isText(v.token) ? { scheme: "jellyfin", token: v.token } : undefined;
  }
  return undefined;
}

export function parseDeviceInfo(v: unknown): DeviceInfo | undefined {
  if (!isObj(v) || !isText(v.id) || !isText(v.name) || !isText(v.client)) return undefined;
  if (!optional(v.version, isText) || (v.api !== "subsonic" && v.api !== "jellyfin")) return undefined;
  const { roles, capabilities } = v;
  if (!Array.isArray(roles) || !roles.every((r) => r === "player" || r === "controller")) return undefined;
  if (!Array.isArray(capabilities) || !capabilities.every((a) => actionSet.has(a))) return undefined;
  return {
    id: v.id, name: v.name, client: v.client, ...(v.version !== undefined && { version: v.version }),
    api: v.api, roles: [...new Set(roles as Role[])], capabilities: [...new Set(capabilities as Action[])],
  };
}

function parseQueue(v: unknown): QueueItem[] | undefined {
  if (!Array.isArray(v)) return undefined;
  const queue: QueueItem[] = [];
  for (const item of v) {
    if (!isObj(item)) return undefined;
    const { id, title, artist, album, durationMs } = item;
    if (!optional(id, isText) || !optional(title, isText) || !optional(artist, isText)) return undefined;
    if (!optional(album, isText) || !optional(durationMs, isMs)) return undefined;
    queue.push({
      ...(id !== undefined && { id }), ...(title !== undefined && { title }),
      ...(artist !== undefined && { artist }), ...(album !== undefined && { album }),
      ...(durationMs !== undefined && { durationMs }),
    });
  }
  return queue;
}

export function parsePlayerState(v: unknown): PlayerState | undefined {
  if (!isObj(v) || !isMs(v.positionMs)) return undefined;
  if (v.status !== "playing" && v.status !== "paused" && v.status !== "stopped") return undefined;
  const queue = v.queue === undefined ? undefined : parseQueue(v.queue);
  if (v.queue !== undefined && !queue) return undefined;
  if (!optional(v.index, isIndex) || !optional(v.volume, isVolume)) return undefined;
  return {
    status: v.status, positionMs: v.positionMs, ...(queue && { queue }),
    ...(v.index !== undefined && { index: v.index }), ...(v.volume !== undefined && { volume: v.volume }),
  };
}

export function parseCommand(v: unknown): Command | undefined {
  if (!isObj(v)) return undefined;
  switch (v.action) {
    case "play": case "pause": case "toggle": case "stop": case "next": case "previous":
      return { action: v.action };
    case "seek":
      return isMs(v.positionMs) ? { action: "seek", positionMs: v.positionMs } : undefined;
    case "setVolume":
      return isVolume(v.volume) ? { action: "setVolume", volume: v.volume } : undefined;
    case "setQueue": {
      const queue = parseQueue(v.queue);
      if (!queue || !isIndex(v.index) || !isMs(v.positionMs) || typeof v.play !== "boolean") return undefined;
      return { action: "setQueue", queue, index: v.index, positionMs: v.positionMs, play: v.play };
    }
  }
  return undefined;
}
