// Runs the hub from environment variables (see README.md, "Running").
import { devAuthenticator, upstreamAuthenticator, type Authenticator, type UpstreamKind } from "./auth.ts";
import { Hub } from "./hub.ts";
import { navidromeIds, noTranslation } from "./ids.ts";
import { listen } from "./server.ts";

const KINDS: readonly UpstreamKind[] = ["navidrome", "subsonic", "jellyfin"];
const log = (line: string) => console.log(`${new Date().toISOString()} ${line}`);
const fail = (line: string): never => {
  console.error(line);
  process.exit(1);
};

const env = process.env;
const kind = (env.SEGUE_UPSTREAM_KIND ?? "navidrome") as UpstreamKind;
if (!KINDS.includes(kind)) fail(`SEGUE_UPSTREAM_KIND must be one of: ${KINDS.join(", ")}`);
const upstream = env.SEGUE_UPSTREAM;
const listenOn = env.SEGUE_LISTEN ?? "127.0.0.1:8480";
const colon = listenOn.lastIndexOf(":");
const host = listenOn.slice(0, colon).replace(/^\[|\]$/g, "");
const port = Number(listenOn.slice(colon + 1));
if (colon < 1 || !Number.isInteger(port)) fail("SEGUE_LISTEN must look like 127.0.0.1:8480");

let authenticate: Authenticator;
if (env.SEGUE_AUTH === "none") {
  log("SEGUE_AUTH=none: every device is accepted as the user \"dev\". Never expose this.");
  authenticate = devAuthenticator;
} else {
  authenticate = upstreamAuthenticator(kind, upstream ?? fail("SEGUE_UPSTREAM is required (the media server's URL)"));
}

const hub = new Hub({ authenticate, translate: kind === "navidrome" ? navidromeIds : noTranslation, log });
const server = await listen(hub, { host, port, info: { server: kind } });
log(`hub listening on ${server.url}, media server ${upstream ?? "(none)"} (${kind})`);

for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.once(signal, () => void server.close().then(() => process.exit(0)));
}
