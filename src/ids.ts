import type { Api } from "./protocol.ts";

/** Expresses an item id from one API in another, or returns undefined when it can't. */
export type IdTranslator = (id: string, from: Api, to: Api) => string | undefined;

/** For servers that speak a single API: ids never need translating. */
export const noTranslation: IdTranslator = (id, from, to) => (from === to ? id : undefined);

/**
 * Navidrome serves one library through both APIs, and the ids are the same 128-bit value: 22 chars of
 * base62 in Subsonic, a 32-hex GUID in Jellyfin. Mirrors navidrome's model/id/id.go and
 * server/jellyfin/dto/ids.go.
 */
export const navidromeIds: IdTranslator = (id, from, to) => {
  if (from === to) return id;
  return from === "subsonic" ? base62ToGuid(id) : guidToBase62(id);
};

// The digits of Go's big.Int.Text(62), which Navidrome uses.
const DIGITS = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";

export function base62ToGuid(id: string): string | undefined {
  if (!/^[0-9a-zA-Z]{22}$/.test(id)) return undefined;
  let value = 0n;
  for (const c of id) value = value * 62n + BigInt(DIGITS.indexOf(c));
  if (value >> 128n) return undefined;
  return value.toString(16).padStart(32, "0");
}

export function guidToBase62(guid: string): string | undefined {
  const hex = guid.replaceAll("-", "").toLowerCase();
  if (!/^[0-9a-f]{32}$/.test(hex)) return undefined;
  // Twelve zero bytes mark Navidrome's reserved GUIDs (libraries, playlist entries): not item ids.
  if (hex.startsWith("0".repeat(24))) return undefined;
  let value = BigInt(`0x${hex}`);
  let id = "";
  for (; value > 0n; value /= 62n) id = DIGITS[Number(value % 62n)] + id;
  return id.padStart(22, "0");
}
