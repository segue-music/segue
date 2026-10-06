package hub

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"slices"
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

// played is what the hub reports of a device made by info(device, ...), signed in with auth.
func played(auth Auth, device, id string, status Status, positionMs int64) Playback {
	return Playback{Auth: auth, Device: device, DeviceID: device, Client: "test", ID: id, Status: status, PositionMs: positionMs}
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
	hubURL, _ := startHub(t, Options{Now: c.Now, Report: report})
	tv, _ := join(t, hubURL, as("alice"), info("tv", Subsonic, player, everything...))
	want := func(id string, status Status, positionMs int64) {
		t.Helper()
		w := played(as("alice"), "tv", id, status, positionMs)
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
	want(dreamOn, Stopped, 60000) // where it got to, so that a server that counts plays can tell
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
	hubURL, _ := startHub(t, Options{Report: report})
	tv, _ := join(t, hubURL, as("alice"), info("tv", Subsonic, player, everything...))
	tv.report(map[string]any{"status": "playing", "positionMs": 0, "index": 0, "queue": subsonicSongs})
	nextReport(t, reported)
	// A track without an id can't be shown, so the last one is taken off.
	tv.report(map[string]any{"status": "playing", "positionMs": 0, "queue": []map[string]any{{"title": "Unknown"}}})
	if got := nextReport(t, reported); got.ID != dreamOn || got.Status != Stopped {
		t.Fatalf("reported %+v, want %s stopped", got, dreamOn)
	}
}

func TestAnotherTrackStopsTheOneBeforeWhereItGotTo(t *testing.T) {
	c := &clock{now: time.UnixMilli(1_790_000_000_000)}
	report, reported := reportsTo()
	hubURL, _ := startHub(t, Options{Now: c.Now, Report: report})
	tv, _ := join(t, hubURL, as("alice"), info("tv", Subsonic, player, everything...))
	tv.report(map[string]any{"status": "playing", "positionMs": 0, "index": 0, "queue": subsonicSongs})
	nextReport(t, reported)
	c.advance(268 * time.Second) // to its end, by itself: the next report is the next track
	tv.report(map[string]any{"status": "playing", "positionMs": 0, "index": 1})
	for _, want := range []Playback{
		played(as("alice"), "tv", dreamOn, Stopped, 268000),
		played(as("alice"), "tv", other, Playing, 0),
	} {
		if got := nextReport(t, reported); got != want {
			t.Fatalf("reported %+v, want %+v", got, want)
		}
	}
}

func TestReportsAgainWhilePlaying(t *testing.T) {
	c := &clock{now: time.UnixMilli(1_790_000_000_000)}
	report, reported := reportsTo()
	hubURL, h := startHub(t, Options{Now: c.Now, Report: report})
	tv, _ := join(t, hubURL, as("alice"), info("tv", Subsonic, player, everything...))
	tv.report(map[string]any{"status": "playing", "positionMs": 0, "index": 0, "queue": subsonicSongs})
	nextReport(t, reported)
	c.advance(reportAgainAfter - time.Second)
	h.reportAgain()
	noReport(t, reported)
	c.advance(time.Second)
	h.reportAgain()
	want := played(as("alice"), "tv", dreamOn, Playing, reportAgainAfter.Milliseconds())
	if got := nextReport(t, reported); got != want {
		t.Fatalf("reported %+v, want %+v", got, want)
	}
	// Paused, it says so again too: the media server keeps showing it.
	tv.report(map[string]any{"status": "paused", "positionMs": 70000})
	nextReport(t, reported)
	c.advance(reportAgainAfter)
	h.reportAgain()
	if got := nextReport(t, reported); got.Status != Paused || got.PositionMs != 70000 {
		t.Fatalf("reported %+v, want paused at 70000", got)
	}
	// Stopped, there is nothing to show.
	tv.report(map[string]any{"status": "stopped", "positionMs": 0})
	nextReport(t, reported)
	c.advance(reportAgainAfter)
	h.reportAgain()
	noReport(t, reported)
}

func noReport(t *testing.T, reported chan Playback) {
	t.Helper()
	select {
	case p := <-reported:
		t.Fatalf("reported %+v", p)
	case <-time.After(50 * time.Millisecond):
	}
}

func TestClosingTwice(t *testing.T) {
	report, _ := reportsTo()
	h := New(Options{Authenticate: byUsername, Report: report, StatePath: filepath.Join(t.TempDir(), "last.json")})
	h.Close()
	h.Close()
}

func TestReportQueueKeepsStopsAndStarts(t *testing.T) {
	var sent []Playback
	q := &reportQueue{
		report:  func(_ context.Context, p Playback) error { sent = append(sent, p); return nil },
		pending: map[*entry][]Playback{},
		wake:    make(chan struct{}, 1),
	}
	tv := &entry{}
	q.add(tv, Playback{ID: dreamOn, Status: Playing, PositionMs: 3000})
	q.add(tv, Playback{ID: dreamOn, Status: Playing, PositionMs: 9000}) // says all the one before did
	q.add(tv, Playback{ID: dreamOn, Status: Stopped, PositionMs: 268000})
	// A track that starts, paused right away: the start stays, since Jellyfin counts a play by it.
	q.add(tv, Playback{ID: other, Status: Playing})
	q.add(tv, Playback{ID: other, Status: Paused, PositionMs: 2000})
	q.add(tv, Playback{ID: other, Status: Playing, PositionMs: 2000})
	q.send()
	want := []Playback{
		{ID: dreamOn, Status: Playing, PositionMs: 9000},
		{ID: dreamOn, Status: Stopped, PositionMs: 268000},
		{ID: other, Status: Playing},
		{ID: other, Status: Playing, PositionMs: 2000},
	}
	if !slices.Equal(sent, want) {
		t.Fatalf("sent %+v, want %+v", sent, want)
	}
}

func TestReportsOnlyForDevicesThatDontReportThemselves(t *testing.T) {
	c := &clock{now: time.UnixMilli(1_790_000_000_000)}
	report, reported := reportsTo()
	hubURL, _ := startHub(t, Options{Now: c.Now, Report: report, Authenticate: func(context.Context, Auth) (string, bool, error) {
		return "alice", true, nil
	}})
	pc, _ := join(t, hubURL, as("alice"), info("pc", Subsonic, controller))
	itself := info("itself", Jellyfin, player)
	itself.ReportsPlayback = true
	jellyfinToken := Auth{Scheme: "jellyfin", Token: "abc"}
	devices := []struct {
		auth   Auth
		device DeviceInfo
		queue  []map[string]any
	}{
		{jellyfinToken, itself, songs},
		{jellyfinToken, info("token on subsonic", Subsonic, player), subsonicSongs}, // the credentials' API isn't the ids'
		{as("alice"), info("subsonic on jellyfin", Jellyfin, player), songs},
	}
	for _, d := range devices {
		dev, _ := join(t, hubURL, d.auth, d.device)
		dev.report(map[string]any{"status": "playing", "positionMs": 0, "queue": d.queue})
		for pc.expect("state").DeviceID != d.device.ID { // until the hub has taken the report in
		}
	}

	for _, d := range []struct {
		auth   Auth
		device DeviceInfo
		queue  []map[string]any
		id     string
	}{
		{Auth{Scheme: "apiKey", APIKey: "k"}, info("tv", Subsonic, player), subsonicSongs, dreamOn},
		{jellyfinToken, info("phone", Jellyfin, player), songs, songs[0]["id"].(string)},
	} {
		dev, _ := join(t, hubURL, d.auth, d.device)
		dev.report(map[string]any{"status": "playing", "positionMs": 0, "queue": d.queue})
		want := played(d.auth, d.device.ID, d.id, Playing, 0)
		if got := nextReport(t, reported); got != want {
			t.Fatalf("reported %+v, want %+v", got, want)
		}
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

// fakeJellyfin is a media server that answers the Jellyfin session reports, under prefix, to the
// token "jf", and hands over each one.
func fakeJellyfin(t *testing.T, prefix string) (string, chan jellyfinRequest) {
	t.Helper()
	requests := make(chan jellyfinRequest, 100)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		authorization := r.Header.Get("Authorization")
		if !strings.HasPrefix(authorization, "MediaBrowser ") || !strings.Contains(authorization, `Token="jf"`) {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		raw, _ := io.ReadAll(r.Body)
		var body map[string]any
		if err := json.Unmarshal(raw, &body); err != nil || r.Header.Get("Content-Type") != "application/json" {
			t.Errorf("%s %s: body %q (%s)", r.Method, r.URL.Path, raw, r.Header.Get("Content-Type"))
		}
		requests <- jellyfinRequest{r.Method + " " + strings.TrimPrefix(r.URL.Path, prefix), authorization, body}
		w.WriteHeader(http.StatusNoContent)
	}))
	t.Cleanup(server.Close)
	return server.URL, requests
}

type jellyfinRequest struct {
	endpoint      string
	authorization string
	body          map[string]any
}

func expectJellyfin(t *testing.T, requests chan jellyfinRequest, endpoint string, want map[string]any) jellyfinRequest {
	t.Helper()
	select {
	case r := <-requests:
		if r.endpoint != endpoint {
			t.Fatalf("asked for %s, want %s", r.endpoint, endpoint)
		}
		for name, value := range want {
			if r.body[name] != value {
				t.Errorf("%s: %s=%v, want %v", endpoint, name, r.body[name], value)
			}
		}
		return r
	default:
		t.Fatalf("the media server wasn't asked for %s", endpoint)
		return jellyfinRequest{}
	}
}

func TestJellyfinReporterStartsReportsProgressAndStops(t *testing.T) {
	base, requests := fakeJellyfin(t, "")
	report := JellyfinReporter(base + "/")
	jf := Auth{Scheme: "jellyfin", Token: "jf"}
	track := songs[0]["id"].(string)
	for i, c := range []struct {
		p        Playback
		endpoint string
		want     map[string]any
	}{
		// A track that starts: Jellyfin counts a play.
		{Playback{Status: Playing, PositionMs: 1500}, "POST /Sessions/Playing",
			map[string]any{"ItemId": track, "PositionTicks": 15_000_000.0, "IsPaused": false}},
		// The same track again: progress, paused or not.
		{Playback{Status: Paused, PositionMs: 42000}, "POST /Sessions/Playing/Progress",
			map[string]any{"ItemId": track, "PositionTicks": 420_000_000.0, "IsPaused": true}},
		{Playback{Status: Playing, PositionMs: 42000}, "POST /Sessions/Playing/Progress",
			map[string]any{"IsPaused": false}},
		// The position always goes with a stop: without it, Jellyfin would count another play.
		{Playback{Status: Stopped, PositionMs: 268000}, "POST /Sessions/Playing/Stopped",
			map[string]any{"ItemId": track, "PositionTicks": 2_680_000_000.0}},
		// Played again from the start after it stopped: another play.
		{Playback{Status: Playing}, "POST /Sessions/Playing", map[string]any{"ItemId": track}},
	} {
		c.p.Auth, c.p.Device, c.p.DeviceID, c.p.Client, c.p.Version, c.p.ID = jf, "Living room+", "d1", "Segue", "0.1.0", track
		if err := report(context.Background(), c.p); err != nil {
			t.Fatal(err)
		}
		r := expectJellyfin(t, requests, c.endpoint, c.want)
		// As the device itself signs its requests, so that the media server takes them for its own.
		const want = `MediaBrowser Client="Segue", Device="Living%20room%2B", DeviceId="d1", Version="0.1.0", Token="jf"`
		if i == 0 && r.authorization != want {
			t.Errorf("Authorization: %s, want %s", r.authorization, want)
		}
	}
}

func TestJellyfinReporterCountsOnlyTracksPlayedFromTheStart(t *testing.T) {
	base, requests := fakeJellyfin(t, "")
	report := JellyfinReporter(base)
	send := func(id string, status Status, positionMs int64) {
		t.Helper()
		p := Playback{Auth: Auth{Scheme: "jellyfin", Token: "jf"}, Device: "tv", DeviceID: "tv", Client: "test", ID: id, Status: status, PositionMs: positionMs}
		if err := report(context.Background(), p); err != nil {
			t.Fatal(err)
		}
	}
	// Moved here halfway (a transfer, or the device back online): it played somewhere already.
	send(dreamOn, Playing, 120000)
	expectJellyfin(t, requests, "POST /Sessions/Playing/Progress", nil)
	send(dreamOn, Stopped, 130000)
	expectJellyfin(t, requests, "POST /Sessions/Playing/Stopped", nil)
	// Loaded paused at the start, then played: one play, when it plays.
	send(other, Paused, 0)
	expectJellyfin(t, requests, "POST /Sessions/Playing/Progress", nil)
	send(other, Playing, 300)
	expectJellyfin(t, requests, "POST /Sessions/Playing", nil)
	send(other, Playing, 900) // a report right after, still at the start
	expectJellyfin(t, requests, "POST /Sessions/Playing/Progress", nil)
}

func TestJellyfinReporterErrors(t *testing.T) {
	base, _ := fakeJellyfin(t, "")
	err := JellyfinReporter(base)(context.Background(), Playback{Auth: Auth{Scheme: "jellyfin", Token: "revoked"}, ID: "x", Status: Playing})
	if err == nil || !strings.Contains(err.Error(), "rejected") {
		t.Fatalf("got %v", err)
	}
}

func TestUpstreamReporterUsesTheAPIOfTheCredentials(t *testing.T) {
	// Navidrome: Subsonic at the root, Jellyfin under /jellyfin.
	requests := make(chan string, 100)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests <- r.URL.Path
		if strings.HasPrefix(r.URL.Path, "/rest/") {
			_, _ = w.Write([]byte(subsonicOK))
		} else {
			w.WriteHeader(http.StatusNoContent)
		}
	}))
	defer server.Close()
	report := UpstreamReporter(KindNavidrome, server.URL)
	jellyfinTrack := Playback{Auth: Auth{Scheme: "jellyfin", Token: "jf"}, Device: "tv", DeviceID: "tv", Client: "test", ID: songs[0]["id"].(string), Status: Playing}
	if err := report(context.Background(), jellyfinTrack); err != nil {
		t.Fatal(err)
	}
	if got := <-requests; got != "/jellyfin/Sessions/Playing" {
		t.Fatalf("asked for %s", got)
	}
	if err := report(context.Background(), Playback{Auth: as("alice"), Device: "pc", ID: dreamOn, Status: Playing}); err != nil {
		t.Fatal(err)
	}
	if got := <-requests; !strings.HasPrefix(got, "/rest/") {
		t.Fatalf("asked for %s", got)
	}
}
