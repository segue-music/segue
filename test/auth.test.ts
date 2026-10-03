import assert from "node:assert/strict";
import { createServer, type IncomingMessage } from "node:http";
import type { AddressInfo } from "node:net";
import { after, before, test } from "node:test";
import { upstreamAuthenticator } from "../src/auth.ts";

// A stand-in media server: Navidrome's Subsonic API at /rest and its Jellyfin API at /jellyfin.
const seen: IncomingMessage[] = [];
const server = createServer((req, res) => {
  seen.push(req);
  const url = new URL(req.url!, "http://x");
  const p = url.searchParams;
  const subsonic = (body: object) => res.end(JSON.stringify({ "subsonic-response": body }));
  if (url.pathname === "/rest/ping.view") {
    subsonic(p.get("u") === "alice" && p.get("t") === "good" ? { status: "ok" } : { status: "failed", error: { code: 40 } });
  } else if (url.pathname === "/rest/tokenInfo.view") {
    subsonic(p.get("apiKey") === "key" ? { status: "ok", tokenInfo: { username: "bob" } } : { status: "failed" });
  } else if (url.pathname === "/jellyfin/Users/Me") {
    if (req.headers.authorization === 'MediaBrowser Token="jf"') res.end(JSON.stringify({ Name: "carol" }));
    else res.writeHead(401).end();
  } else {
    res.writeHead(500).end();
  }
});
let base = "";
before(() => new Promise<void>((done) => server.listen(0, "127.0.0.1", () => {
  base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  done();
})));
after(() => new Promise<void>((done) => server.close(() => done())));

test("asks the media server who the credentials belong to", async () => {
  const auth = upstreamAuthenticator("navidrome", base);
  assert.equal(await auth({ scheme: "subsonic", username: "alice", token: "good", salt: "s" }), "alice");
  assert.equal(await auth({ scheme: "subsonic", username: "alice", token: "bad", salt: "s" }), undefined);
  assert.equal(await auth({ scheme: "apiKey", apiKey: "key" }), "bob");
  assert.equal(await auth({ scheme: "jellyfin", token: "jf" }), "carol");
  assert.equal(await auth({ scheme: "jellyfin", token: "nope" }), undefined);
});

test("caches a successful check", async () => {
  const auth = upstreamAuthenticator("navidrome", base);
  const credentials = { scheme: "subsonic", username: "alice", token: "good", salt: "cache" } as const;
  const before = seen.length;
  await auth(credentials);
  await auth(credentials);
  assert.equal(seen.length - before, 1);
});

test("only accepts the APIs the media server has", async () => {
  assert.equal(await upstreamAuthenticator("subsonic", base)({ scheme: "jellyfin", token: "jf" }), undefined);
  assert.equal(await upstreamAuthenticator("jellyfin", `${base}/jellyfin`)({ scheme: "apiKey", apiKey: "key" }), undefined);
  assert.equal(await upstreamAuthenticator("navidrome", base)({ scheme: "jellyfin", token: 'jf" x="y' }), undefined);
});

test("throws when the media server fails, rather than calling the credentials wrong", async () => {
  await assert.rejects(upstreamAuthenticator("jellyfin", `${base}/broken`)({ scheme: "jellyfin", token: "jf" }));
});
