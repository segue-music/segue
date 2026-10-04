package hub

import (
	"context"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"
)

// reportsTo returns a Reporter that hands every report to the channel.
func reportsTo() (Reporter, chan Playback) {
	reported := make(chan Playback, 100)
	return func(_ context.Context, p Playback) error {
		reported <- p
		return nil
	}, reported
}

func nextReport(t *testing.T, reported chan Playback) Playback {
	t.Helper()
	select {
	case p := <-reported:
		return p
	case <-time.After(2 * time.Second):
		t.Fatal("nothing reported to the media server")
		return Playback{}
	}
}

const (
	dreamOn = "5QFKvMsJrd57QE2Le2dKKo"
	other   = "1bsBLnXdqpdu6b7fcVUeK5"
)

var subsonicSongs = []map[string]any{
	{"id": dreamOn, "title": "Dream On", "durationMs": 268000},
	{"id": other, "title": "Other", "durationMs": 200000},
}

func TestReportsWhatADevicePlays(t *testing.T) {
	c := &clock{now: time.UnixMilli(1_790_000_000_000)}
	report, reported := reportsTo()
	url, _ := startHub(t, Options{Now: c.Now, Report: report})
	tv, _ := join(t, url, as("alice"), info("tv", Subsonic, player, everything...))
	want := func(id string, status Status, positionMs int64) {
		t.Helper()
		w := Playback{Auth: as("alice"), Device: "tv", ID: id, Status: status, PositionMs: positionMs}
		if got := nextReport(t, reported); got != w {
			t.Fatalf("reported %+v, want %+v", got, w)
		}
	}

	tv.report(map[string]any{"status": "playing", "positionMs": 1000, "index": 0, "queue": subsonicSongs})
	want(dreamOn, Playing, 1000)
	// The volume isn't news to the media server, and the track plays on where it would be anyway.
	c.advance(4 * time.Second)
	tv.report(map[string]any{"status": "playing", "positionMs": 5000, "volume": 50})
	tv.report(map[string]any{"status": "paused", "positionMs": 5000})
	want(dreamOn, Paused, 5000)
	tv.report(map[string]any{"status": "paused", "positionMs": 60000}) // a seek
	want(dreamOn, Paused, 60000)
	tv.report(map[string]any{"status": "playing", "positionMs": 60000})
	want(dreamOn, Playing, 60000)
	tv.report(map[string]any{"status": "playing", "positionMs": 0, "index": 1})
	want(other, Playing, 0)
	tv.report(map[string]any{"status": "stopped", "positionMs": 0})
	want(other, Stopped, 0)
	// Still stopped, on another track: nothing to take off.
	tv.report(map[string]any{"status": "stopped", "positionMs": 0, "index": 0})
	tv.report(map[string]any{"status": "playing", "positionMs": 0})
	want(dreamOn, Playing, 0)

	// Offline, it plays nothing the hub can tell.
	c.advance(3 * time.Second)
	_ = tv.ws.Close()
	want(dreamOn, Stopped, 3000)
}

func TestAStopNamesTheTrackTheMediaServerHas(t *testing.T) {
	report, reported := reportsTo()
	url, _ := startHub(t, Options{Report: report})
	tv, _ := join(t, url, as("alice"), info("tv", Subsonic, player, everything...))
	tv.report(map[string]any{"status": "playing", "positionMs": 0, "index": 0, "queue": subsonicSongs})
	nextReport(t, reported)
	// A track without an id can't be shown, so the last one is taken off.
	tv.report(map[string]any{"status": "playing", "positionMs": 0, "queue": []map[string]any{{"title": "Unknown"}}})
	if got := nextReport(t, reported); got.ID != dreamOn || got.Status != Stopped {
		t.Fatalf("reported %+v, want %s stopped", got, dreamOn)
	}
}

func TestReportsOnlyForSubsonicDevicesThatDontReportThemselves(t *testing.T) {
	c := &clock{now: time.UnixMilli(1_790_000_000_000)}
	report, reported := reportsTo()
	url, _ := startHub(t, Options{Now: c.Now, Report: report, Authenticate: func(context.Context, Auth) (string, bool, error) {
		return "alice", true, nil
	}})
	pc, _ := join(t, url, as("alice"), info("pc", Subsonic, controller))
	itself := info("itself", Subsonic, player)
	itself.ReportsPlayback = true
	devices := []struct {
		auth   Auth
		device DeviceInfo
		queue  []map[string]any
	}{
		{as("alice"), itself, subsonicSongs},
		{Auth{Scheme: "jellyfin", Token: "abc"}, info("jellyfin", Jellyfin, player), songs},
		{as("alice"), info("on jellyfin", Jellyfin, player), songs}, // its ids aren't Subsonic's
	}
	for _, d := range devices {
		dev, _ := join(t, url, d.auth, d.device)
		dev.report(map[string]any{"status": "playing", "positionMs": 0, "queue": d.queue})
		for pc.expect("state").DeviceID != d.device.ID { // until the hub has taken the report in
		}
	}

	key := Auth{Scheme: "apiKey", APIKey: "k"}
	tv, _ := join(t, url, key, info("tv", Subsonic, player))
	tv.report(map[string]any{"status": "playing", "positionMs": 0, "queue": subsonicSongs})
	want := Playback{Auth: key, Device: "tv", ID: dreamOn, Status: Playing}
	if got := nextReport(t, reported); got != want {
		t.Fatalf("reported %+v, want %+v", got, want)
	}
}

// fakeSubsonic is a media server that answers the reporting endpoints and hands over each request.
func fakeSubsonic(t *testing.T, extensions bool, answer string) (string, chan *http.Request) {
	t.Helper()
	requests := make(chan *http.Request, 100)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests <- r
		switch strings.TrimSuffix(r.URL.Path, ".view") {
		case "/rest/getOpenSubsonicExtensions":
			if !extensions {
				http.NotFound(w, r)
				return
			}
			_, _ = w.Write([]byte(`{"subsonic-response": {"status": "ok", "openSubsonic": true,
				"openSubsonicExtensions": [{"name": "songLyrics", "versions": [1]}, {"name": "playbackReport", "versions": [1]}]}}`))
		case "/rest/reportPlayback", "/rest/scrobble":
			_, _ = w.Write([]byte(answer))
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(server.Close)
	return server.URL, requests
}

const subsonicOK = `{"subsonic-response": {"status": "ok"}}`

func expectRequest(t *testing.T, requests chan *http.Request, endpoint string, want url.Values) {
	t.Helper()
	select {
	case r := <-requests:
		if got := strings.TrimSuffix(r.URL.Path, ".view"); got != "/rest/"+endpoint {
			t.Fatalf("asked for %s, want /rest/%s", got, endpoint)
		}
		query := r.URL.Query()
		for name := range want {
			if query.Get(name) != want.Get(name) {
				t.Errorf("%s=%q, want %q", name, query.Get(name), want.Get(name))
			}
		}
	default:
		t.Fatalf("the media server wasn't asked for %s", endpoint)
	}
}

func TestSubsonicReporterUsesReportPlayback(t *testing.T) {
	base, requests := fakeSubsonic(t, true, subsonicOK)
	report := SubsonicReporter(base + "/")
	p := Playback{Auth: as("alice"), Device: "Living room TV", ID: dreamOn, Status: Paused, PositionMs: 42000}
	if err := report(context.Background(), p); err != nil {
		t.Fatal(err)
	}
	expectRequest(t, requests, "getOpenSubsonicExtensions", nil)
	expectRequest(t, requests, "reportPlayback", url.Values{
		"u": {"alice"}, "t": {"-"}, "s": {"-"}, "c": {"Living room TV"}, "f": {"json"},
		"mediaId": {dreamOn}, "mediaType": {"song"}, "positionMs": {"42000"}, "state": {"paused"},
		"ignoreScrobble": {"true"},
	})

	// The server's extensions are asked once, not on every report.
	p.Status = Stopped
	if err := report(context.Background(), p); err != nil {
		t.Fatal(err)
	}
	expectRequest(t, requests, "reportPlayback", url.Values{"state": {"stopped"}})
}

func TestSubsonicReporterFallsBackToNowPlaying(t *testing.T) {
	base, requests := fakeSubsonic(t, false, subsonicOK)
	report := SubsonicReporter(base)
	key := Auth{Scheme: "apiKey", APIKey: "k"}
	p := Playback{Auth: key, Device: "tv", ID: dreamOn, Status: Playing, PositionMs: 42500}
	if err := report(context.Background(), p); err != nil {
		t.Fatal(err)
	}
	expectRequest(t, requests, "getOpenSubsonicExtensions", nil)
	expectRequest(t, requests, "scrobble", url.Values{
		"apiKey": {"k"}, "u": nil, "c": {"tv"}, "id": {dreamOn}, "submission": {"false"}, "position": {"42"},
	})

	// Scrobble's now playing knows no pause or stop: nothing to send.
	p.Status = Paused
	if err := report(context.Background(), p); err != nil {
		t.Fatal(err)
	}
	if len(requests) != 0 {
		t.Fatalf("asked for %s", (<-requests).URL.Path)
	}
}

func TestSubsonicReporterErrors(t *testing.T) {
	base, _ := fakeSubsonic(t, true, `{"subsonic-response": {"status": "failed", "error": {"code": 40, "message": "Wrong username or password"}}}`)
	err := SubsonicReporter(base)(context.Background(), Playback{Auth: as("alice"), Device: "tv", ID: dreamOn, Status: Playing})
	if err == nil || !strings.Contains(err.Error(), "Wrong username or password") {
		t.Fatalf("got %v", err)
	}
}
