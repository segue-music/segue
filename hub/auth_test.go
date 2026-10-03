package hub

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// fakeMediaServer is Navidrome's Subsonic API at /rest and its Jellyfin API at /jellyfin.
func fakeMediaServer(t *testing.T) (string, *atomic.Int32) {
	var calls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		q := r.URL.Query()
		subsonic := func(body map[string]any) {
			_ = json.NewEncoder(w).Encode(map[string]any{"subsonic-response": body})
		}
		switch r.URL.Path {
		case "/rest/ping.view":
			if q.Get("u") == "alice" && q.Get("t") == "good" && q.Get("c") == clientName {
				subsonic(map[string]any{"status": "ok"})
			} else {
				subsonic(map[string]any{"status": "failed", "error": map[string]any{"code": 40}})
			}
		case "/rest/tokenInfo.view":
			if q.Get("apiKey") == "key" {
				subsonic(map[string]any{"status": "ok", "tokenInfo": map[string]any{"username": "bob"}})
			} else {
				subsonic(map[string]any{"status": "failed"})
			}
		case "/jellyfin/Users/Me":
			if r.Header.Get("Authorization") == `MediaBrowser Token="jf"` {
				_, _ = w.Write([]byte(`{"Name":"carol","Id":"x"}`))
			} else {
				w.WriteHeader(http.StatusUnauthorized)
			}
		default:
			w.WriteHeader(http.StatusInternalServerError)
		}
	}))
	t.Cleanup(server.Close)
	return server.URL, &calls
}

func TestUpstreamAuthenticator(t *testing.T) {
	base, _ := fakeMediaServer(t)
	auth := UpstreamAuthenticator(KindNavidrome, base, time.Minute)
	for _, c := range []struct {
		auth Auth
		user string
		ok   bool
	}{
		{Auth{Scheme: "subsonic", Username: "alice", Token: "good", Salt: "s"}, "alice", true},
		{Auth{Scheme: "subsonic", Username: "alice", Token: "bad", Salt: "s"}, "", false},
		{Auth{Scheme: "apiKey", APIKey: "key"}, "bob", true},
		{Auth{Scheme: "apiKey", APIKey: "nope"}, "", false},
		{Auth{Scheme: "jellyfin", Token: "jf"}, "carol", true},
		{Auth{Scheme: "jellyfin", Token: "nope"}, "", false},
		{Auth{Scheme: "jellyfin", Token: `jf" x="y`}, "", false},
	} {
		user, ok, err := auth(context.Background(), c.auth)
		if err != nil || ok != c.ok || (ok && user != c.user) {
			t.Errorf("%+v: got %q %v %v", c.auth, user, ok, err)
		}
	}
}

func TestUpstreamAuthenticatorCaches(t *testing.T) {
	base, calls := fakeMediaServer(t)
	auth := UpstreamAuthenticator(KindNavidrome, base, time.Minute)
	good := Auth{Scheme: "subsonic", Username: "alice", Token: "good", Salt: "s"}
	for range 3 {
		_, _, _ = auth(context.Background(), good)
	}
	if calls.Load() != 1 {
		t.Fatalf("%d calls to the media server", calls.Load())
	}
}

func TestUpstreamAuthenticatorOnlyAcceptsTheServersAPIs(t *testing.T) {
	base, _ := fakeMediaServer(t)
	if _, ok, _ := UpstreamAuthenticator(KindSubsonic, base, 0)(context.Background(), Auth{Scheme: "jellyfin", Token: "jf"}); ok {
		t.Error("a Subsonic-only server accepted a Jellyfin token")
	}
	if _, ok, _ := UpstreamAuthenticator(KindJellyfin, base+"/jellyfin", 0)(context.Background(), Auth{Scheme: "apiKey", APIKey: "key"}); ok {
		t.Error("a Jellyfin server accepted a Subsonic API key")
	}
}

func TestUpstreamAuthenticatorErrorsDontLeakCredentials(t *testing.T) {
	base, _ := fakeMediaServer(t)
	_, ok, err := UpstreamAuthenticator(KindJellyfin, base+"/broken", 0)(context.Background(), Auth{Scheme: "jellyfin", Token: "jf"})
	if ok || err == nil {
		t.Fatalf("got ok=%v err=%v, want an error", ok, err)
	}
	_, _, err = UpstreamAuthenticator(KindSubsonic, "http://127.0.0.1:1", 0)(context.Background(), Auth{Scheme: "subsonic", Username: "alice", Token: "secret-token", Salt: "secret-salt"})
	if err == nil || strings.Contains(err.Error(), "secret") {
		t.Fatalf("error %v", err)
	}
}
