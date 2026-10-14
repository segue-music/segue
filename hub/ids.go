package hub

import (
	"bytes"
	"encoding/hex"
	"fmt"
	"math/big"
	"strings"
)

// IDTranslator expresses an item id from one API in another. ok is false when it can't.
type IDTranslator func(id string, from, to API) (translated string, ok bool)

// NoTranslation is for servers that speak a single API: ids never need translating.
func NoTranslation(id string, from, to API) (string, bool) {
	return id, from == to
}

// NavidromeIDs translates between Navidrome's two APIs. The ids are the same 128-bit value: 22
// chars of base62 in Subsonic, a 32-hex GUID in Jellyfin. Mirrors navidrome's model/id/id.go and
// server/jellyfin/dto/ids.go.
func NavidromeIDs(id string, from, to API) (string, bool) {
	switch {
	case from == to:
		return id, true
	case from == Subsonic:
		return base62ToGUID(id)
	default:
		return guidToBase62(id)
	}
}

func base62ToGUID(id string) (string, bool) {
	if len(id) != 22 || strings.IndexFunc(id, func(r rune) bool { return !isAlnum(r) }) >= 0 {
		return "", false
	}

	value, ok := new(big.Int).SetString(id, 62) // Go's base-62 digits, as Navidrome uses
	if !ok || value.BitLen() > 128 {
		return "", false
	}

	return hex.EncodeToString(value.FillBytes(make([]byte, 16))), true
}

func guidToBase62(guid string) (string, bool) {
	b, err := hex.DecodeString(strings.ReplaceAll(guid, "-", ""))
	if err != nil || len(b) != 16 {
		return "", false
	}

	// Twelve zero bytes mark Navidrome's reserved GUIDs (libraries, playlist entries): not item ids.
	if bytes.Equal(b[:12], make([]byte, 12)) {
		return "", false
	}

	return fmt.Sprintf("%022s", new(big.Int).SetBytes(b).Text(62)), true
}

func isAlnum(r rune) bool {
	return (r >= '0' && r <= '9') || (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z')
}
