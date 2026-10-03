import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

/** The hub binary: SEGUE_HUB_BIN, or the one `go build -o segue-hub ./cmd/segue-hub` makes in ../hub. */
const HUB_BIN = process.env.SEGUE_HUB_BIN ?? fileURLToPath(new URL("../../hub/segue-hub", import.meta.url));

export type HubProcess = {
  /** The WebSocket URL. */
  url: string;
  stop(): Promise<void>;
};

/**
 * Starts the Go hub on a free port, accepting any device as the Subsonic user it claims
 * (SEGUE_AUTH=none). For the demo and the tests.
 */
export function startHub(opts: { log?: (line: string) => void } = {}): Promise<HubProcess> {
  const child = spawn(HUB_BIN, [], {
    env: { ...process.env, SEGUE_AUTH: "none", SEGUE_LISTEN: "127.0.0.1:0" },
    stdio: ["ignore", "pipe", "inherit"],
  });
  const exited = new Promise<void>((resolve) => child.once("exit", () => resolve()));
  return new Promise((resolve, reject) => {
    child.once("error", (err) => reject(new Error(`can't run the hub at ${HUB_BIN}: ${err.message}`)));
    let buffered = "";
    child.stdout.setEncoding("utf8").on("data", (chunk: string) => {
      buffered += chunk;
      let newline;
      while ((newline = buffered.indexOf("\n")) >= 0) {
        const line = buffered.slice(0, newline);
        buffered = buffered.slice(newline + 1);
        opts.log?.(line);
        const listening = /msg="hub listening" url=http:\/\/(\S+)/.exec(line);
        if (listening) {
          resolve({
            url: `ws://${listening[1]}/v1/ws`,
            stop: () => {
              child.kill("SIGTERM");
              return exited;
            },
          });
        }
      }
    });
    void exited.then(() => reject(new Error("the hub exited before listening")));
  });
}
