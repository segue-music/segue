// The reference client and the pretend player against the real (Go) hub: checks that both sides
// read the protocol the same way. Needs the hub binary (see examples/hub-process.ts).
import assert from "node:assert/strict";
import { after, afterEach, before, test } from "node:test";
import { SegueClient } from "../src/client.ts";
import type { Api, Auth } from "../src/protocol.ts";
import { FakePlayer } from "../examples/fake-player.ts";
import { startHub, type HubProcess } from "../examples/hub-process.ts";

let hub: HubProcess;
before(async () => {
  hub = await startHub();
});
after(() => hub.stop());

// The hub groups devices by user, so each test signs in as a user of its own.
let users = 0;
const newUser = () => `user${++users}`;
const as = (user: string): Auth => ({ scheme: "subsonic", username: user, token: "-", salt: "-" });

const cleanups: (() => void)[] = [];
afterEach(() => {
  for (const cleanup of cleanups.splice(0)) cleanup();
});

async function player(user: string, id: string, api: Api = "subsonic"): Promise<FakePlayer> {
  const p = new FakePlayer({ url: hub.url, id, name: id, api, auth: as(user) });
  await p.connect();
  cleanups.push(() => p.client.close());
  return p;
}

async function controller(user: string, id: string): Promise<SegueClient> {
  const c = new SegueClient({
    url: hub.url, auth: as(user),
    device: { id, name: id, client: "test", api: "subsonic", roles: ["controller"], capabilities: [] },
  });
  await c.connect();
  cleanups.push(() => c.close());
  return c;
}

async function until(condition: () => boolean, what: string): Promise<void> {
  for (const deadline = Date.now() + 2_000; !condition(); await new Promise((r) => setTimeout(r, 5))) {
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
  }
}

const SONGS = [
  { id: "c032d12530e3c18d843d13651f9689ac", title: "Dream On", durationMs: 268_000 },
  { id: "ffffffffffffffffffffffffffffffff", title: "Other", durationMs: 200_000 },
];

test("a rejected hello rejects connect() with the close code", async () => {
  const client = new SegueClient({
    url: hub.url, auth: as(newUser()),
    device: { id: "x", name: "", client: "test", api: "subsonic", roles: [], capabilities: [] },
  });
  await assert.rejects(client.connect(), { code: 4002 });
});

test("sees the user's other devices, and only theirs", async () => {
  const alice = newUser();
  await player(alice, "phone");
  await player(newUser(), "someone-else");
  const pc = await controller(alice, "pc");
  assert.deepEqual([...pc.devices.keys()], ["phone"]);
  await player(alice, "tv");
  await until(() => pc.devices.get("tv")?.online === true, "the TV to show up");
});

test("gets other players' state in its own ids, on the hub's clock", async () => {
  const user = newUser();
  const phone = await player(user, "phone", "jellyfin");
  const tv = await player(user, "tv", "subsonic");
  phone.play(SONGS, 0, 10_000);
  await until(() => tv.client.devices.get("phone")?.state !== undefined, "the state");
  const state = tv.client.devices.get("phone")!.state!;
  assert.equal(state.status, "playing");
  assert.equal(state.queue?.[0].id, "5QFKvMsJrd57QE2Le2dKKo");
  assert.ok(tv.client.positionMs("phone")! >= 10_000);
});

test("commands reach the player, and its answer comes back", async () => {
  const user = newUser();
  const tv = await player(user, "tv");
  const pc = await controller(user, "pc");
  tv.play(SONGS);
  assert.equal((await pc.command("tv", { action: "pause" })).ok, true);
  assert.equal(tv.status, "paused");
  assert.equal((await pc.command("tv", { action: "setVolume", volume: 30 })).ok, true);
  assert.equal(tv.volume, 30);
  assert.equal((await pc.command("tv", { action: "previous" })).ok, true, "the first track: back to its start");
  assert.equal(tv.index, 0);
  await pc.command("tv", { action: "next" });
  assert.equal((await pc.command("tv", { action: "next" })).error, "no such track");
  assert.equal((await tv.client.command("pc", { action: "play" })).error, "notPlayer");
});

test("transfer moves the queue at the current position and pauses the source", async () => {
  const user = newUser();
  const phone = await player(user, "phone", "jellyfin");
  const tv = await player(user, "tv", "subsonic");
  const pc = await controller(user, "pc");
  phone.play(SONGS, 1, 30_000);
  await until(() => pc.devices.get("phone")?.state !== undefined, "the state");
  await new Promise((r) => setTimeout(r, 200));
  assert.equal((await pc.transfer("phone", "tv")).ok, true);
  assert.equal(tv.status, "playing");
  assert.equal(tv.index, 1);
  assert.ok(tv.positionMs >= 30_200 && tv.positionMs < 32_000, `position ${tv.positionMs}`);
  assert.deepEqual(tv.queue.map((item) => item.id), ["5QFKvMsJrd57QE2Le2dKKo", "7N42dgm5tFLK9N8MT7fHC7"]);
  await until(() => phone.status === "paused", "the phone to pause");
});

test("continue here: picks up the queue of a device that closed", async () => {
  const user = newUser();
  const phone = await player(user, "phone");
  const tv = await player(user, "tv");
  phone.play(SONGS, 0, 5_000);
  await until(() => tv.client.devices.get("phone")?.state !== undefined, "the state");
  phone.client.close();
  await until(() => tv.client.devices.get("phone")?.online === false, "the phone to go offline");
  assert.equal((await tv.client.transfer("phone", "tv")).ok, true);
  assert.equal(tv.status, "playing");
  assert.equal(tv.queue[0].id, SONGS[0].id);
});
