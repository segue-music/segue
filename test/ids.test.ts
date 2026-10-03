import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import { test } from "node:test";
import { base62ToGuid, guidToBase62, navidromeIds, noTranslation } from "../src/ids.ts";

// Pairs computed independently (Python big ints with Go's base-62 digits).
const PAIRS = [
  ["5QFKvMsJrd57QE2Le2dKKo", "c032d12530e3c18d843d13651f9689ac"],
  ["7N42dgm5tFLK9N8MT7fHC7", "ffffffffffffffffffffffffffffffff"],
];

test("translates Navidrome ids both ways", () => {
  for (const [base62, guid] of PAIRS) {
    assert.equal(navidromeIds(base62, "subsonic", "jellyfin"), guid);
    assert.equal(navidromeIds(guid, "jellyfin", "subsonic"), base62);
  }
  assert.equal(guidToBase62("C032D125-30E3-C18D-843D-13651F9689AC"), PAIRS[0][0]);
});

test("round-trips random 128-bit ids", () => {
  for (let i = 0; i < 200; i++) {
    const guid = randomBytes(16).toString("hex");
    if (guid.startsWith("0".repeat(24))) continue;
    assert.equal(base62ToGuid(guidToBase62(guid)!), guid);
  }
});

test("refuses what isn't an item id", () => {
  assert.equal(base62ToGuid("short"), undefined);
  assert.equal(base62ToGuid("7N42dgm5tFLK9N8MT7fHC8"), undefined, "overflows 128 bits");
  assert.equal(guidToBase62("00000000000000000000000001000001"), undefined, "Navidrome library GUID");
  assert.equal(guidToBase62("not-a-guid"), undefined);
  assert.equal(noTranslation("x", "subsonic", "jellyfin"), undefined);
  assert.equal(noTranslation("x", "jellyfin", "jellyfin"), "x");
});
