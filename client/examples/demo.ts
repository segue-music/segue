// Starts the Go hub, an iPhone playing through the Jellyfin API, a TV on the Subsonic API and a PC
// that only controls; the PC moves the music from the iPhone to the TV. Run with `npm run demo`,
// after building the hub (README.md).
import { SegueClient } from "../src/client.ts";
import { FakePlayer } from "./fake-player.ts";
import { startHub } from "./hub-process.ts";

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
const seconds = (ms = 0) => `${(ms / 1000).toFixed(1)}s`;

const hub = await startHub({ log: (line) => console.log(`  [hub] ${line.replace(/^time=\S+ /, "")}`) });
const url = hub.url;

const iphone = new FakePlayer({ url, id: "iphone", name: "iPhone (Jellify)", api: "jellyfin" });
const tv = new FakePlayer({ url, id: "tv", name: "Living room TV (Symfonium)", api: "subsonic" });
const pc = new SegueClient({
  url,
  auth: { scheme: "subsonic", username: "dev", token: "-", salt: "-" },
  device: { id: "pc", name: "PC (Feishin)", client: "demo", api: "subsonic", roles: ["controller"], capabilities: [] },
});

function show(title: string): void {
  console.log(`\n${title}, as the PC sees it:`);
  for (const device of pc.devices.values()) {
    const state = device.state;
    const track = state?.queue?.[state.index ?? 0];
    const playing = track ? `${state?.status} "${track.title}" at ${seconds(pc.positionMs(device.id))}` : "idle";
    console.log(`  ${device.name.padEnd(28)} ${device.online ? "online " : "offline"}  ${playing}`);
  }
}

await Promise.all([iphone.connect(), tv.connect(), pc.connect()]);

// Jellyfin-style GUIDs: the TV will get the same songs as Subsonic ids.
iphone.play([
  { id: "c032d12530e3c18d843d13651f9689ac", title: "Dream On", artist: "Aerosmith", durationMs: 268_000 },
  { id: "4be1b0e4a1f84c2f9d0c7b3e5a6f1d2e", title: "Diário de um Detento", artist: "Racionais MC's", durationMs: 451_000 },
], 0, 42_000);
await sleep(1_500);
show("The iPhone is playing");

console.log("\nPC: transfer the iPhone's queue to the TV");
const result = await pc.transfer("iphone", "tv");
console.log(`  result: ${JSON.stringify(result)}`);
await sleep(100);
show("After the transfer");
console.log(`\nThe TV got Subsonic ids: ${tv.queue.map((item) => item.id).join(", ")}`);

for (const client of [iphone.client, tv.client, pc]) client.close();
await hub.stop();
