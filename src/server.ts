import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { WebSocketServer, type WebSocket } from "ws";
import type { Hub } from "./hub.ts";
import { PROTOCOL_VERSION } from "./protocol.ts";

export type ListenOptions = {
  host: string;
  port: number;
  /** Extra fields for GET /v1/info, e.g. the kind of media server behind the hub. */
  info?: Record<string, unknown>;
};

export type Listening = { url: string; close(): Promise<void> };

const HEARTBEAT_MS = 30_000;
const SWEEP_MS = 10 * 60_000;

// The hub answers at the root and under /connect, where it sits on the media server's origin
// (SPEC.md, "Discovery"), whether or not the reverse proxy strips that prefix.
const route = (url = "/") => new URL(url, "http://hub").pathname.replace(/^\/connect(?=\/)/, "");

/** Serves the hub over HTTP: GET /v1/info and the WebSocket at /v1/ws. */
export function listen(hub: Hub, opts: ListenOptions): Promise<Listening> {
  const info = JSON.stringify({ protocol: "segue", versions: [PROTOCOL_VERSION], ...opts.info });
  const wss = new WebSocketServer({ noServer: true, maxPayload: 1 << 20 });
  // A device that vanished without closing (a phone out of signal) is dropped within two heartbeats.
  const alive = new WeakSet<WebSocket>();

  const http = createServer((req, res) => {
    if (req.method === "GET" && route(req.url) === "/v1/info") {
      res.writeHead(200, { "content-type": "application/json" }).end(info);
    } else {
      res.writeHead(404).end();
    }
  });
  http.on("upgrade", (req, socket, head) => {
    if (route(req.url) !== "/v1/ws") return void socket.destroy();
    wss.handleUpgrade(req, socket, head, (ws) => {
      alive.add(ws);
      ws.on("pong", () => alive.add(ws));
      attach(hub, ws);
    });
  });

  const heartbeat = setInterval(() => {
    for (const ws of wss.clients) {
      if (!alive.delete(ws)) ws.terminate();
      else ws.ping();
    }
  }, HEARTBEAT_MS);
  const sweep = setInterval(() => hub.sweep(), SWEEP_MS);

  return new Promise((resolve, reject) => {
    http.once("error", reject);
    http.listen(opts.port, opts.host, () => {
      const { address, port } = http.address() as AddressInfo;
      resolve({
        url: `http://${address.includes(":") ? `[${address}]` : address}:${port}`,
        close: () => {
          clearInterval(heartbeat);
          clearInterval(sweep);
          for (const ws of wss.clients) ws.terminate();
          wss.close();
          return new Promise((done) => http.close(() => done()));
        },
      });
    });
  });
}

function attach(hub: Hub, ws: WebSocket): void {
  const session = hub.open({
    send: (msg) => {
      if (ws.readyState === ws.OPEN) ws.send(JSON.stringify(msg));
    },
    close: (code, reason) => ws.close(code, reason),
  });
  ws.on("message", (data, isBinary) => {
    if (!isBinary) session.message(data.toString());
  });
  ws.on("close", () => session.closed());
  ws.on("error", () => ws.terminate()); // the "close" that follows ends the session
}
