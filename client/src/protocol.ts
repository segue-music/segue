// Wire format of the Segue protocol, version 1 (draft), for clients. SPEC.md explains the semantics;
// the hub's side of the same types is ../../hub/protocol.go.

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
  /** The media server didn't answer: reconnect with backoff. */
  unavailable: 1011,
} as const;

/** Where playback is now, extrapolated from the last report. */
export function currentPositionMs(state: StampedState, now: number): number {
  if (state.status !== "playing") return state.positionMs;
  const position = state.positionMs + Math.max(0, now - state.at);
  const duration = state.queue?.[state.index ?? 0]?.durationMs;
  return duration === undefined ? position : Math.min(position, duration);
}
