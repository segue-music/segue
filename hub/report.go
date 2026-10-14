package hub

import (
	"bytes"
	"cmp"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"net/url"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Playback is what the hub tells the media server about one device (SPEC.md, section 12).
type Playback struct {
	Auth       Auth   // the device's own credentials
	Device     string // the device's name, which the media server shows as the player
	DeviceID   string // the device's id, app and version, with which Jellyfin's API knows it too
	Client     string
	Version    string
	ID         string // the track, in the API of the credentials: Jellyfin's for a jellyfin token
	Status     Status
	PositionMs int64
}

// Reporter tells the media server about a device's playback. The hub calls it from a goroutine of
// its own, one report at a time.
type Reporter func(ctx context.Context, p Playback) error

// SubsonicReporter reports through the Subsonic API at baseURL: with reportPlayback (OpenSubsonic's
// playbackReport extension, in Navidrome since 0.62) where the server offers it, otherwise with
// scrobble's "now playing", which knows no pause or stop. Neither counts as a play.
func SubsonicReporter(baseURL string) Reporter {
	base := strings.TrimRight(baseURL, "/")
	client := &http.Client{Timeout: 5 * time.Second}

	var mu sync.Mutex
	var extended bool     // the server has playbackReport
	var recheck time.Time // when to ask the server again

	return func(ctx context.Context, p Playback) error {
		mu.Lock()
		defer mu.Unlock()

		query := subsonicQuery(p.Auth, p.Device)

		if now := time.Now(); !now.Before(recheck) {
			var answer subsonicAnswer

			_, err := getJSON(ctx, client, base+"/rest/getOpenSubsonicExtensions.view?"+query.Encode(), nil, &answer)
			extended = slices.ContainsFunc(answer.Response.Extensions, func(e extension) bool { return e.Name == "playbackReport" })
			// An answer holds for an hour, so that an upgraded server is noticed; a failure, a minute.
			recheck = now.Add(time.Hour)

			if err != nil {
				recheck = now.Add(time.Minute)
			}
		}

		endpoint := "reportPlayback"

		if extended {
			query.Set("mediaId", p.ID)
			query.Set("mediaType", "song")
			query.Set("positionMs", strconv.FormatInt(p.PositionMs, 10))
			query.Set("state", string(p.Status))
			query.Set("ignoreScrobble", "true") // what plays, not a play
		} else {
			if p.Status != Playing {
				return nil
			}

			endpoint = "scrobble"
			query.Set("id", p.ID)
			query.Set("submission", "false")
			query.Set("position", strconv.FormatInt(p.PositionMs/1000, 10)) // Navidrome's, in seconds
		}

		var answer subsonicAnswer

		found, err := getJSON(ctx, client, base+"/rest/"+endpoint+".view?"+query.Encode(), nil, &answer)

		switch {
		case err != nil:
			return err
		case !found:
			return fmt.Errorf("%s: credentials rejected", endpoint)
		case answer.Response.Status != "ok":
			return fmt.Errorf("%s: %s", endpoint, cmp.Or(answer.Response.Error.Message, "failed"))
		}

		return nil
	}
}

type subsonicAnswer struct {
	Response struct {
		Status string `json:"status"`
		Error  struct {
			Message string `json:"message"`
		} `json:"error"`
		Extensions []extension `json:"openSubsonicExtensions"`
	} `json:"subsonic-response"`
}

type extension struct {
	Name string `json:"name"`
}

// JellyfinReporter reports through Jellyfin's sessions API at baseURL, signed as the device itself
// signs its requests: its token, id, app, name and version. Jellyfin counts a play on each
// Sessions/Playing, so only a track that starts playing from its start gets one; a track it hears
// of later (moved from another device, or the device back online) and the same track again go to
// Sessions/Playing/Progress, which shows it without counting. Sessions/Playing/Stopped always says
// where the track stopped: without it, Jellyfin would count another play, and Navidrome's Jellyfin
// API counts one by it.
func JellyfinReporter(baseURL string) Reporter {
	base := strings.TrimRight(baseURL, "/")
	client := &http.Client{Timeout: 5 * time.Second}

	type started struct {
		id      string
		counted bool // Sessions/Playing went for it
	}

	var mu sync.Mutex

	playing := map[string]started{} // by token: the track the media server has as playing

	return func(ctx context.Context, p Playback) error {
		mu.Lock()
		defer mu.Unlock()

		token := p.Auth.Token
		last := playing[token]
		now := started{id: p.ID, counted: last.id == p.ID && last.counted}
		endpoint := "/Sessions/Playing/Progress"

		switch {
		case p.Status == Stopped:
			endpoint = "/Sessions/Playing/Stopped"
		case starts(p) && !now.counted:
			endpoint, now.counted = "/Sessions/Playing", true
		}

		body, err := json.Marshal(map[string]any{
			"ItemId":        p.ID,
			"PositionTicks": p.PositionMs * 10_000, // 10 million to the second
			"IsPaused":      p.Status == Paused,
			"CanSeek":       true,
			"PlayMethod":    "DirectPlay",
		})
		if err != nil {
			return err
		}

		req, err := http.NewRequestWithContext(ctx, http.MethodPost, base+endpoint, bytes.NewReader(body))
		if err != nil {
			return err
		}

		req.Header.Set("Authorization", jellyfinAuthorization(p))
		req.Header.Set("Content-Type", "application/json")

		res, err := client.Do(req)
		if err != nil {
			var urlErr *url.Error
			if errors.As(err, &urlErr) {
				err = urlErr.Err
			}

			return fmt.Errorf("%s: %w", endpoint, err)
		}

		_ = res.Body.Close()

		switch {
		case res.StatusCode == http.StatusUnauthorized || res.StatusCode == http.StatusForbidden:
			return fmt.Errorf("%s: credentials rejected", endpoint)
		case res.StatusCode/100 != 2:
			return fmt.Errorf("%s: HTTP %d", endpoint, res.StatusCode)
		}

		if p.Status == Stopped {
			delete(playing, token)
		} else {
			playing[token] = now
		}

		return nil
	}
}

// jellyfinAuthorization signs a report as the device signs its own requests. Jellyfin would take
// the token alone for its device; Navidrome's Jellyfin API needs the rest to tell the player, and
// without a player it shows the playback nameless and counts no play. The values are URL-encoded,
// spaces as %20: Jellyfin decodes a + as a space, and Navidrome doesn't.
func jellyfinAuthorization(p Playback) string {
	var fields []string

	for _, field := range [][2]string{
		{"Client", p.Client}, {"Device", p.Device}, {"DeviceId", p.DeviceID}, {"Version", p.Version}, {"Token", p.Auth.Token},
	} {
		if field[1] != "" { // an empty one Jellyfin takes from the device the token belongs to
			fields = append(fields, field[0]+`="`+strings.ReplaceAll(url.QueryEscape(field[1]), "+", "%20")+`"`)
		}
	}

	return "MediaBrowser " + strings.Join(fields, ", ")
}

// UpstreamReporter reports to the media server at baseURL in the API of each device's credentials:
// Jellyfin's sessions for a jellyfin token (under /jellyfin on Navidrome), the Subsonic API for the
// others.
func UpstreamReporter(kind UpstreamKind, baseURL string) Reporter {
	subsonic, jellyfin := SubsonicReporter(baseURL), JellyfinReporter(jellyfinBase(kind, baseURL))

	return func(ctx context.Context, p Playback) error {
		if p.Auth.Scheme == SchemeJellyfin {
			return jellyfin(ctx, p)
		}

		return subsonic(ctx, p)
	}
}

// seekMs is how far a device's position may stray from where the hub expects it before the media
// server hears of it: further, it was a seek.
const seekMs = 2000

// starts says whether p is a track that starts playing from its start, which Jellyfin counts as a
// play.
func starts(p Playback) bool { return p.Status == Playing && p.PositionMs < seekMs }

// reportAgainAfter is how long a playing or paused device goes without a report before the media
// server hears of it again, unchanged: Jellyfin stops a playback it hears nothing of for a while.
const reportAgainAfter = time.Minute

// notePlayback tells the media server what e plays now, if that changed for it: another track,
// play, pause or stop, a seek, or e going offline (SPEC.md, section 12). Call with h.mu held.
func (h *Hub) notePlayback(e *entry) {
	if h.reports == nil || e.state == nil || e.info.ReportsPlayback || !reportable(e) {
		return
	}

	now := h.opts.Now().UnixMilli()
	p := Playback{
		Auth: e.auth, Device: e.info.Name, DeviceID: e.info.ID, Client: e.info.Client, Version: e.info.Version,
		Status: e.state.Status, PositionMs: e.state.positionAt(now),
	}

	if item, ok := e.state.current(); ok {
		p.ID = item.ID
	}

	if p.ID == "" || e.conn == nil {
		p.Status = Stopped // nothing the media server could show, or nothing the hub can tell
	}

	last := e.reported

	var reached int64 // where the track the media server has got to

	if last != nil {
		reached = last.PositionMs

		if last.Status == Playing {
			reached += now - e.reportedAt
		}
	}

	switch {
	case p.Status == Stopped:
		if last == nil || last.Status == Stopped {
			return
		}

		// The media server ignores a stop for another track than the one it has, and counts a play
		// by where it stopped.
		p.ID, p.PositionMs = last.ID, reached
	case last != nil && last.ID == p.ID && last.Status == p.Status && last.Device == p.Device:
		if d := p.PositionMs - reached; -seekMs <= d && d <= seekMs && now-e.reportedAt < reportAgainAfter.Milliseconds() {
			return
		}
	case last != nil && last.Status != Stopped && last.ID != p.ID:
		// Another track: the one before stops where it got to.
		stop := *last
		stop.Status, stop.PositionMs = Stopped, reached
		h.reports.add(e, stop)
	}

	e.reported, e.reportedAt = &p, now
	h.reports.add(e, p)
}

// reportable says whether the media server can hear of e's playback: its ids are in the API of its
// credentials, which the hub reports with.
func reportable(e *entry) bool {
	switch e.auth.Scheme {
	case SchemeSubsonic, SchemeAPIKey:
		return e.info.API == Subsonic
	case SchemeJellyfin:
		return e.info.API == Jellyfin
	}

	return false
}

// reportAgain tells the media server again what each connected device plays, where it hasn't heard
// of it for reportAgainAfter.
func (h *Hub) reportAgain() {
	h.mu.Lock()
	defer h.mu.Unlock()

	for _, devices := range h.users {
		for _, e := range devices {
			if e.conn != nil {
				h.notePlayback(e)
			}
		}
	}
}

// reportQueue hands the hub's reports to the Reporter from a goroutine of its own, so the hub never
// waits on the media server. Of a device's reports of one track waiting, only the newest is sent:
// it says all the media server needs. Stops and starts are always sent, in order: the media server
// hears where a track ended before the next one starts, and Jellyfin counts a play by a start.
type reportQueue struct {
	report  Reporter
	log     *slog.Logger
	mu      sync.Mutex
	pending map[*entry][]Playback
	wake    chan struct{}
	done    chan struct{}
	stopped chan struct{}
	once    sync.Once
}

func startReports(report Reporter, log *slog.Logger) *reportQueue {
	q := &reportQueue{
		report: report, log: log, pending: map[*entry][]Playback{},
		wake: make(chan struct{}, 1), done: make(chan struct{}), stopped: make(chan struct{}),
	}

	go q.run()

	return q
}

func (q *reportQueue) add(e *entry, p Playback) {
	q.mu.Lock()

	list := q.pending[e]
	n := len(list)
	if n > 0 && list[n-1].ID == p.ID && p.Status != Stopped && list[n-1].Status != Stopped && !starts(list[n-1]) {
		list[n-1] = p // it says all the one waiting did
	} else {
		list = append(list, p)
	}

	q.pending[e] = list
	q.mu.Unlock()

	select {
	case q.wake <- struct{}{}:
	default: // a round is already due, and it will take this report
	}
}

func (q *reportQueue) run() {
	defer close(q.stopped)

	for {
		select {
		case <-q.wake:
			q.send()
		case <-q.done:
			q.send()
			return
		}
	}
}

func (q *reportQueue) send() {
	q.mu.Lock()

	reports := q.pending
	q.pending = map[*entry][]Playback{}
	q.mu.Unlock()

	for _, list := range reports {
		for _, p := range list {
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)

			if err := q.report(ctx, p); err != nil {
				q.log.Warn("can't report to the media server", "device", p.Device, "err", err)
			}

			cancel()
		}
	}
}

func (q *reportQueue) close() {
	q.once.Do(func() { close(q.done) })
	<-q.stopped
}
