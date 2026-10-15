package hub

import (
	"context"
	"encoding/json"
	"errors"
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
			body["type"] = "navidrome"
			_ = json.NewEncoder(w).Encode(map[string]any{"subsonic-response": body})
		}

		switch r.URL.Path {
		case "/rest/ping.view":
			switch {
			case q.Get("u") == "":
				subsonic(map[string]any{"status": "failed", "error": map[string]any{"code": 10}})
			case q.Get("u") == "alice" && q.Get("t") == "good" && q.Get("c") == clientName:
				subsonic(map[string]any{"status": "ok"})
			default:
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

func TestMediaServerAuthenticator(t *testing.T) {
	base, _ := fakeMediaServer(t)
	auth := MediaServerAuthenticator(KindNavidrome, base, time.Minute)

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

func TestMediaServerAuthenticatorCaches(t *testing.T) {
	base, calls := fakeMediaServer(t)
	auth := MediaServerAuthenticator(KindNavidrome, base, time.Minute)
	good := Auth{Scheme: "subsonic", Username: "alice", Token: "good", Salt: "s"}

	for range 3 {
		_, _, _ = auth(context.Background(), good)
	}

	if calls.Load() != 1 {
		t.Fatalf("%d calls to the media server", calls.Load())
	}
}

func TestMediaServerAuthenticatorOnlyAcceptsTheServersAPIs(t *testing.T) {
	base, _ := fakeMediaServer(t)

	if _, ok, _ := MediaServerAuthenticator(KindSubsonic, base, 0)(context.Background(), Auth{Scheme: "jellyfin", Token: "jf"}); ok {
		t.Error("a Subsonic-only server accepted a Jellyfin token")
	}

	if _, ok, _ := MediaServerAuthenticator(KindJellyfin, base+"/jellyfin", 0)(context.Background(), Auth{Scheme: "apiKey", APIKey: "key"}); ok {
		t.Error("a Jellyfin server accepted a Subsonic API key")
	}
}

func TestMediaServerAuthenticatorErrorsDontLeakCredentials(t *testing.T) {
	base, _ := fakeMediaServer(t)
	_, ok, err := MediaServerAuthenticator(KindJellyfin, base+"/broken", 0)(context.Background(), Auth{Scheme: "jellyfin", Token: "jf"})
	if ok || err == nil {
		t.Fatalf("got ok=%v err=%v, want an error", ok, err)
	}

	_, _, err = MediaServerAuthenticator(KindSubsonic, "http://127.0.0.1:1", 0)(context.Background(), Auth{Scheme: "subsonic", Username: "alice", Token: "secret-token", Salt: "secret-salt"})
	if err == nil || strings.Contains(err.Error(), "secret") {
		t.Fatalf("error %v", err)
	}
}

func TestDetectMediaServer(t *testing.T) {
	navidrome, _ := fakeMediaServer(t)

	serve := func(handler http.HandlerFunc) string {
		server := httptest.NewServer(handler)

		t.Cleanup(server.Close)

		return server.URL
	}

	otherSubsonic := serve(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/music/rest/ping.view" || r.URL.Query().Get("f") != "json" {
			http.NotFound(w, r)
			return
		}

		_, _ = w.Write([]byte(`{"subsonic-response":{"status":"failed","version":"1.16.1","type":"gonic","error":{"code":10}}}`))
	})
	jellyfin := serve(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/System/Info/Public" {
			http.NotFound(w, r)
			return
		}

		_, _ = w.Write([]byte(`{"ServerName":"music","Version":"10.10.7","ProductName":"Jellyfin Server","Id":"4f6e1b2c"}`))
	})

	for _, c := range []struct {
		name, url string
		kind      MediaServerKind
	}{
		{"navidrome", navidrome, KindNavidrome},
		{"navidrome, with a slash", navidrome + "/", KindNavidrome},
		{"another subsonic server, under a path", otherSubsonic + "/music", KindSubsonic},
		{"jellyfin", jellyfin, KindJellyfin},
	} {
		kind, err := DetectMediaServer(context.Background(), c.url)
		if err != nil || kind != c.kind {
			t.Errorf("%s: got %q %v, want %q", c.name, kind, err, c.kind)
		}
	}
}

func TestDetectMediaServerTellsAWrongURLFromOneThatIsDown(t *testing.T) {
	website := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte("<!doctype html><title>Not a media server</title>"))
	}))
	defer website.Close()

	if _, err := DetectMediaServer(context.Background(), website.URL); !errors.Is(err, ErrNotAMediaServer) {
		t.Errorf("a website: got %v, want ErrNotAMediaServer", err)
	}

	starting := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadGateway) // the proxy, while the media server starts
	}))
	defer starting.Close()

	for _, url := range []string{starting.URL, "http://127.0.0.1:1"} {
		if _, err := DetectMediaServer(context.Background(), url); err == nil || errors.Is(err, ErrNotAMediaServer) {
			t.Errorf("%s: got %v, want an error to retry on", url, err)
		}
	}
}
