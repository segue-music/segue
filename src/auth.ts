import { createHash } from "node:crypto";
import type { Auth } from "./protocol.ts";

/**
 * Finds the media server user behind a device's credentials: the username, or undefined when the
 * media server rejects them. Throws when the media server can't be asked (network error, HTTP 5xx),
 * so the hub can tell a wrong password from "try again later".
 */
export type Authenticator = (auth: Auth) => Promise<string | undefined>;

export type UpstreamKind = "navidrome" | "subsonic" | "jellyfin";

/** Accepts anyone as the user "dev". For demos and tests only. */
export const devAuthenticator: Authenticator = async () => "dev";

const CLIENT = "segue-hub";

/**
 * Checks credentials against the media server itself, so the hub keeps no users or passwords of its
 * own. A successful check is cached for `cacheMs`.
 */
export function upstreamAuthenticator(kind: UpstreamKind, baseUrl: string, cacheMs = 5 * 60_000): Authenticator {
  const base = baseUrl.replace(/\/+$/, "");
  const jellyfinBase = kind === "navidrome" ? `${base}/jellyfin` : base;
  const cache = new Map<string, { user: string; until: number }>();

  async function check(auth: Auth): Promise<string | undefined> {
    if (auth.scheme === "jellyfin") {
      if (kind === "subsonic" || /["\\\p{Cc}]/u.test(auth.token)) return undefined;
      // Token only, without Client/Device: Navidrome then doesn't list the hub among its players.
      const me = await getJson(`${jellyfinBase}/Users/Me`, { authorization: `MediaBrowser Token="${auth.token}"` });
      return typeof me?.Name === "string" ? me.Name : undefined;
    }
    if (kind === "jellyfin") return undefined;
    // An API key doesn't say whose it is: tokenInfo (OpenSubsonic apiKeyAuthentication) does.
    const credentials: Record<string, string> = auth.scheme === "subsonic"
      ? { u: auth.username, t: auth.token, s: auth.salt }
      : { apiKey: auth.apiKey };
    const query = new URLSearchParams({ ...credentials, v: "1.16.1", c: CLIENT, f: "json" });
    const endpoint = auth.scheme === "subsonic" ? "ping" : "tokenInfo";
    const response = (await getJson(`${base}/rest/${endpoint}.view?${query}`))?.["subsonic-response"];
    if (response?.status !== "ok") return undefined;
    const user = auth.scheme === "subsonic" ? auth.username : response.tokenInfo?.username;
    return typeof user === "string" ? user : undefined;
  }

  return async (auth) => {
    const key = createHash("sha256").update(JSON.stringify(auth)).digest("hex");
    const now = Date.now();
    const hit = cache.get(key);
    if (hit && hit.until > now) return hit.user;
    const user = await check(auth);
    if (user !== undefined) {
      if (cache.size >= 1000) for (const [k, v] of cache) if (v.until <= now) cache.delete(k);
      cache.set(key, { user, until: now + cacheMs });
    }
    return user;
  };
}

async function getJson(url: string, headers: Record<string, string> = {}): Promise<Record<string, any> | undefined> {
  const response = await fetch(url, { headers, signal: AbortSignal.timeout(5_000) });
  if (response.status === 401 || response.status === 403) return undefined;
  if (!response.ok) throw new Error(`${url.split("?")[0]}: HTTP ${response.status}`);
  return response.json();
}
