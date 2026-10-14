package hub

import (
	"crypto/rand"
	"encoding/hex"
	"strings"
	"testing"
)

// Pairs computed independently (Python big ints with Go's base-62 digits).
var idPairs = [][2]string{
	{"5QFKvMsJrd57QE2Le2dKKo", "c032d12530e3c18d843d13651f9689ac"},
	{"7N42dgm5tFLK9N8MT7fHC7", "ffffffffffffffffffffffffffffffff"},
}

func TestNavidromeIDs(t *testing.T) {
	for _, pair := range idPairs {
		if got, ok := NavidromeIDs(pair[0], Subsonic, Jellyfin); !ok || got != pair[1] {
			t.Errorf("%s → %s, %v", pair[0], got, ok)
		}

		if got, ok := NavidromeIDs(pair[1], Jellyfin, Subsonic); !ok || got != pair[0] {
			t.Errorf("%s → %s, %v", pair[1], got, ok)
		}
	}

	if got, _ := NavidromeIDs("C032D125-30E3-C18D-843D-13651F9689AC", Jellyfin, Subsonic); got != idPairs[0][0] {
		t.Errorf("dashed uppercase GUID → %s", got)
	}
}

func TestNavidromeIDsRoundTrip(t *testing.T) {
	b := make([]byte, 16)

	for range 500 {
		_, _ = rand.Read(b)
		b[0] |= 1 // stay out of the reserved range
		guid := hex.EncodeToString(b)
		id, ok := guidToBase62(guid)

		if back, ok2 := base62ToGUID(id); !ok || !ok2 || back != guid {
			t.Fatalf("%s → %s → %s", guid, id, back)
		}
	}
}

func TestNavidromeIDsRejects(t *testing.T) {
	for _, id := range []string{"short", "7N42dgm5tFLK9N8MT7fHC8", "+QFKvMsJrd57QE2Le2dKKo", strings.Repeat("é", 11)} {
		if _, ok := base62ToGUID(id); ok {
			t.Errorf("base62ToGUID(%q) accepted", id)
		}
	}

	for _, guid := range []string{"00000000000000000000000001000001", "not-a-guid", "c032d125"} {
		if _, ok := guidToBase62(guid); ok {
			t.Errorf("guidToBase62(%q) accepted", guid)
		}
	}

	if _, ok := NoTranslation("x", Subsonic, Jellyfin); ok {
		t.Error("NoTranslation translated across APIs")
	}
}
