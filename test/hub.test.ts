import assert from "node:assert/strict";
import { afterEach, test } from "node:test";
import type { Authenticator } from "../src/auth.ts";
import { SegueClient } from "../src/client.ts";
import { Hub, type HubOptions } from "../src/hub.ts";
import { navidromeIds } from "../src/ids.ts";
import type { Api, Auth } from "../src/protocol.ts";
import { listen } from "../src/server.ts";
import { FakePlayer } from "../examples/fake-player.ts";

// Every Subsonic username is accepted as itself, so tests can have several users.
const byUsername: Authenticator = async (auth) => (auth.scheme === "subsonic" ? auth.username : undefined);
const as = (username: string): Auth => ({ scheme: "subsonic", username, token: "-", salt: "-" });

const cleanups: (() => unknown)[] = [];
afterEach(async () => {
  for (const cleanup of cleanups.splice(0).reverse()) await cleanup();
});

async function startHub(opts: Partial<HubOptions> = {}): Promise<string> {
  const hub = new Hub({ authenticate: byUsername, translate: navidromeIds, ...opts });
  const server = await listen(hub, { host: "127.0.0.1", port: 0 });
  cleanups.push(() => server.close());
  return `${server.url.replace(/^http/, "ws")}/v1/ws`;
}

async function player(url: string, id: string, api: Api = "subsonic", user = "alice"): Promise<FakePlayer> {
  const p = new FakePlayer({ url, id, name: id, api, auth: as(user) });
  await p.connect();
  cleanups.push(() => p.client.close());
  return p;
}

async function controller(url: string, id: string, user = "alice"): Promise<SegueClient> {
  const c = new SegueClient({
    url, auth: as(user), device: { id, name: id, client: "test", api: "subsonic", roles: ["controller"], capabilities: [] },
  });
  await c.connect();
  cleanups.push(() => c.close());
  return c;
}

async function until(condition: () => boolean, what = "condition"): Promise<void> {
  for (const deadline = Date.now() + 2_000; !condition(); await new Promise((r) => setTimeout(r, 5))) {
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
  }
}

const SONGS = [
  { id: "c032d12530e3c18d843d13651f9689ac", title: "Dream On", durationMs: 268_000 },
  { id: "ffffffffffffffffffffffffffffffff", title: "Other", durationMs: 200_000 },
];

test("refuses credentials the media server rejects", async () => {
  const url = await startHub({ authenticate: async () => undefined });
  await assert.rejects(player(url, "phone"), { code: 4001 });
});

test("closes a connection whose first message isn't a hello", async () => {
  const url = await startHub();
  const ws = new WebSocket(url);
  const closed = new Promise<number>((resolve) => ws.addEventListener("close", (e) => resolve(e.code)));
  ws.addEventListener("open", () => ws.send(JSON.stringify({ type: "state" })));
  assert.equal(await closed, 4002);
});

test("shows each user their own devices only", async () => {
  const url = await startHub();
  await player(url, "alice-phone");
  await player(url, "bob-phone", "subsonic", "bob");
  const pc = await controller(url, "alice-pc");
  assert.deepEqual([...pc.devices.keys()], ["alice-phone"]);
  const tv = await player(url, "alice-tv");
  await until(() => pc.devices.has("alice-tv"), "the TV to show up");
  assert.equal(tv.client.devices.size, 2);
});

test("relays state with the hub's clock, in each recipient's ids", async () => {
  const url = await startHub();
  const phone = await player(url, "phone", "jellyfin");
  const tv = await player(url, "tv", "subsonic");
  phone.play(SONGS, 0, 10_000);
  await until(() => tv.client.devices.get("phone")?.state !== undefined, "the state");
  const state = tv.client.devices.get("phone")!.state!;
  assert.equal(state.status, "playing");
  assert.equal(state.queue?.[0].id, "5QFKvMsJrd57QE2Le2dKKo");
  assert.ok(Math.abs(state.at - Date.now()) < 1_000);
  assert.ok(tv.client.positionMs("phone")! >= 10_000);
});

test("routes a command and returns the player's answer", async () => {
  const url = await startHub();
  const tv = await player(url, "tv");
  const pc = await controller(url, "pc");
  tv.play(SONGS);
  assert.deepEqual(await pc.command("tv", { action: "pause" }), { type: "result", re: "r1", ok: true });
  assert.equal(tv.status, "paused");
  assert.equal((await pc.command("tv", { action: "previous" })).error, "no such track");
  assert.equal((await pc.command("nowhere", { action: "play" })).error, "unknownDevice");
  assert.equal((await tv.client.command("pc", { action: "play" })).error, "notPlayer");
});

test("doesn't send a player commands it didn't declare", async () => {
  const url = await startHub();
  let received = 0;
  const speaker = new SegueClient({
    url, auth: as("alice"), onCommand: () => void received++,
    device: { id: "speaker", name: "speaker", client: "test", api: "subsonic", roles: ["player"], capabilities: ["pause"] },
  });
  await speaker.connect();
  cleanups.push(() => speaker.close());
  const pc = await controller(url, "pc");
  assert.equal((await pc.command("speaker", { action: "next" })).error, "unsupported");
  assert.equal((await pc.command("speaker", { action: "pause" })).ok, true);
  assert.equal(received, 1);
});

test("transfers the queue at the current position and pauses the source", async () => {
  const url = await startHub();
  const phone = await player(url, "phone", "jellyfin");
  const tv = await player(url, "tv", "subsonic");
  const pc = await controller(url, "pc");
  phone.play(SONGS, 1, 30_000);
  await until(() => pc.devices.get("phone")?.state !== undefined, "the state");
  await new Promise((r) => setTimeout(r, 200));
  assert.equal((await pc.transfer("phone", "tv")).ok, true);
  assert.equal(tv.status, "playing");
  assert.equal(tv.index, 1);
  assert.ok(tv.positionMs >= 30_200 && tv.positionMs < 32_000, `position ${tv.positionMs}`);
  assert.deepEqual(tv.queue.map((item) => item.id), ["5QFKvMsJrd57QE2Le2dKKo", "7N42dgm5tFLK9N8MT7fHC7"]);
  assert.equal(phone.status, "paused");
});

test("keeps an offline device's last state, so its queue can be picked up", async () => {
  const url = await startHub();
  const phone = await player(url, "phone");
  const tv = await player(url, "tv");
  phone.play(SONGS, 0, 5_000);
  await until(() => tv.client.devices.get("phone")?.state !== undefined, "the state");
  phone.client.close();
  await until(() => tv.client.devices.get("phone")?.online === false, "the phone to go offline");
  assert.equal((await tv.client.transfer("phone", "tv")).ok, true, "continue here");
  assert.equal(tv.status, "playing");
  assert.equal(tv.queue[0].id, SONGS[0].id);
});

test("a device that reconnects replaces its old connection", async () => {
  const url = await startHub();
  const pc = await controller(url, "pc");
  const first = new WebSocket(url);
  const firstClosed = new Promise<number>((resolve) => first.addEventListener("close", (e) => resolve(e.code)));
  first.addEventListener("open", () => first.send(JSON.stringify({
    type: "hello", protocol: 1, auth: as("alice"),
    device: { id: "phone", name: "old app", client: "test", api: "subsonic", roles: ["player"], capabilities: [] },
  })));
  await until(() => pc.devices.get("phone")?.name === "old app", "the first connection");
  const second = await player(url, "phone");
  assert.equal(await firstClosed, 4003);
  await new Promise((r) => setTimeout(r, 50)); // the old connection's close must not mark it offline
  assert.equal(pc.devices.get("phone")?.online, true);
  assert.equal((await pc.command("phone", { action: "setVolume", volume: 40 })).ok, true);
  assert.equal(second.volume, 40);
});

test("gives up on a player that doesn't answer", async () => {
  const url = await startHub({ commandTimeoutMs: 100 });
  const stuck = new SegueClient({
    url, auth: as("alice"), onCommand: () => new Promise(() => {}),
    device: { id: "stuck", name: "stuck", client: "test", api: "subsonic", roles: ["player"], capabilities: ["play"] },
  });
  await stuck.connect();
  cleanups.push(() => stuck.close());
  const pc = await controller(url, "pc");
  assert.equal((await pc.command("stuck", { action: "play" })).error, "timeout");
});
