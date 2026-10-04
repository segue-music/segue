package hub

import (
	"cmp"
	"context"
	"fmt"
	"log/slog"
	"net/http"
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
	ID         string // the track, in the Subsonic API
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

// seekMs is how far a device's position may stray from where the hub expects it before the media
// server hears of it: further, it was a seek.
const seekMs = 2000

// notePlayback tells the media server what e plays now, if that changed for it: another track,
// play, pause or stop, a seek, or e going offline (SPEC.md, section 12). Call with h.mu held.
func (h *Hub) notePlayback(e *entry) {
	if h.reports == nil || e.state == nil || e.info.ReportsPlayback || e.info.API != Subsonic ||
		(e.auth.Scheme != "subsonic" && e.auth.Scheme != "apiKey") {
		return
	}
	now := h.opts.Now().UnixMilli()
	p := Playback{Auth: e.auth, Device: e.info.Name, Status: e.state.Status, PositionMs: e.state.positionAt(now)}
	if item, ok := e.state.current(); ok {
		p.ID = item.ID
	}
	if p.ID == "" || e.conn == nil {
		p.Status = Stopped // nothing the media server could show, or nothing the hub can tell
	}
	last := e.reported
	if p.Status == Stopped {
		if last == nil || last.Status == Stopped {
			return
		}
		p.ID = last.ID // the media server ignores a stop for another track than the one it has
	} else if last != nil && last.ID == p.ID && last.Status == p.Status && last.Device == p.Device {
		expected := last.PositionMs
		if last.Status == Playing {
			expected += now - e.reportedAt
		}
		if d := p.PositionMs - expected; -seekMs <= d && d <= seekMs {
			return
		}
	}
	e.reported, e.reportedAt = &p, now
	h.reports.add(e, p)
}

// reportQueue hands the hub's reports to the Reporter from a goroutine of its own, so the hub never
// waits on the media server. Only a device's newest report waiting is sent: it says all the media
// server needs.
type reportQueue struct {
	report  Reporter
	log     *slog.Logger
	mu      sync.Mutex
	pending map[*entry]Playback
	wake    chan struct{}
	done    chan struct{}
	stopped chan struct{}
	once    sync.Once
}

func startReports(report Reporter, log *slog.Logger) *reportQueue {
	q := &reportQueue{
		report: report, log: log, pending: map[*entry]Playback{},
		wake: make(chan struct{}, 1), done: make(chan struct{}), stopped: make(chan struct{}),
	}
	go q.run()
	return q
}

func (q *reportQueue) add(e *entry, p Playback) {
	q.mu.Lock()
	q.pending[e] = p
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
	q.pending = map[*entry]Playback{}
	q.mu.Unlock()
	for _, p := range reports {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		if err := q.report(ctx, p); err != nil {
			q.log.Warn("can't report to the media server", "device", p.Device, "err", err)
		}
		cancel()
	}
}

func (q *reportQueue) close() {
	q.once.Do(func() { close(q.done) })
	<-q.stopped
}
