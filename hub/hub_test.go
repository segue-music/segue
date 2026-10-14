package hub

import (
	"context"
	"encoding/json"
	"errors"
	"net/http/httptest"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

// A hub message, decoded into one struct whatever its type.
type received struct {
	Type       string       `json:"type"`
	User       string       `json:"user"`
	ServerTime int64        `json:"serverTime"`
	Devices    []Device     `json:"devices"`
	Device     Device       `json:"device"`
	DeviceID   string       `json:"deviceId"`
	State      StampedState `json:"state"`
	ID         string       `json:"id"`
	From       string       `json:"from"`
	Command    Command      `json:"command"`
	Re         string       `json:"re"`
	OK         bool         `json:"ok"`
	Error      string       `json:"error"`
	// welcome
	LastPlayback *lastPlaybackMsg `json:"lastPlayback"`
}

// testDevice is a device driven by hand: the test reads what the hub sends and answers itself.
type testDevice struct {
	t      *testing.T
	ws     *websocket.Conn
	msgs   chan received
	closed chan int // the close code, once the hub closes the connection
}

type clock struct {
	mu  sync.Mutex
	now time.Time
}

func (c *clock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()

	return c.now
}

func (c *clock) advance(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.now = c.now.Add(d)
}

// Every Subsonic username is accepted as itself, so tests can have several users.
var byUsername Authenticator = func(_ context.Context, a Auth) (string, bool, error) {
	return a.Username, a.Scheme == "subsonic", nil
}

func startHub(t *testing.T, opts Options) (string, *Hub) {
	t.Helper()

	if opts.Authenticate == nil {
		opts.Authenticate = byUsername
	}

	if opts.Translate == nil {
		opts.Translate = NavidromeIDs
	}

	h := New(opts)

	t.Cleanup(h.Close)

	server := httptest.NewServer(h.Handler(nil))

	t.Cleanup(server.Close)

	return "ws" + strings.TrimPrefix(server.URL, "http") + "/v1/ws", h
}

func info(id string, api API, roles []Role, capabilities ...Action) DeviceInfo {
	return DeviceInfo{ID: id, Name: id, Client: "test", API: api, Roles: roles, Capabilities: capabilities}
}

var (
	player     = []Role{RolePlayer, RoleController}
	controller = []Role{RoleController}
	everything = []Action{ActPlay, ActPause, ActToggle, ActStop, ActNext, ActPrevious, ActJump, ActSeek, ActSetVolume, ActSetQueue, ActSetRepeat, ActSetShuffle, ActAddToQueue, ActMoveInQueue, ActRemoveFromQueue}
)

func as(user string) Auth { return Auth{Scheme: "subsonic", Username: user, Token: "-", Salt: "-"} }

// dial connects and sends the hello. It doesn't wait for the welcome.
func dial(t *testing.T, url string, auth Auth, device DeviceInfo) *testDevice {
	t.Helper()

	ws, _, err := websocket.DefaultDialer.Dial(url, nil)
	if err != nil {
		t.Fatal(err)
	}

	d := &testDevice{t: t, ws: ws, msgs: make(chan received, 100), closed: make(chan int, 1)}

	t.Cleanup(func() { _ = ws.Close() })
	go func() {
		for {
			_, data, err := ws.ReadMessage()
			if err != nil {
				var closeErr *websocket.CloseError
				if errors.As(err, &closeErr) {
					d.closed <- closeErr.Code
				}

				close(d.msgs)
				return
			}

			var msg received

			if err := json.Unmarshal(data, &msg); err != nil {
				t.Errorf("undecodable message %s: %v", data, err)
			}

			d.msgs <- msg
		}
	}()
	d.send(map[string]any{"type": "hello", "protocol": ProtocolVersion, "auth": auth, "device": device})

	return d
}

// join connects and waits for the welcome.
func join(t *testing.T, url string, auth Auth, device DeviceInfo) (*testDevice, received) {
	t.Helper()

	d := dial(t, url, auth, device)

	return d, d.expect("welcome")
}

func (d *testDevice) send(msg any) {
	d.t.Helper()

	if err := d.ws.WriteJSON(msg); err != nil {
		d.t.Fatal(err)
	}
}

// expect returns the next message of a type, skipping others.
func (d *testDevice) expect(typ string) received {
	d.t.Helper()

	timeout := time.After(2 * time.Second)

	for {
		select {
		case msg, ok := <-d.msgs:
			if !ok {
				d.t.Fatalf("connection closed while waiting for %q", typ)
			}

			if msg.Type == typ {
				return msg
			}
		case <-timeout:
			d.t.Fatalf("no %q message", typ)
		}
	}
}

// expectDevice waits for news of a device that satisfies a condition.
func (d *testDevice) expectDevice(id string, ok func(Device) bool) Device {
	d.t.Helper()

	for {
		msg := d.expect("device")
		if msg.Device.ID == id && ok(msg.Device) {
			return msg.Device
		}
	}
}

func (d *testDevice) expectClose() int {
	d.t.Helper()

	select {
	case code := <-d.closed:
		return code
	case <-time.After(2 * time.Second):
		d.t.Fatal("the hub didn't close the connection")
		return 0
	}
}

// obey answers the next command with ok (or the error) and returns it.
func (d *testDevice) obey(err string) Command {
	d.t.Helper()

	msg := d.expect("command")

	d.send(map[string]any{"type": "result", "re": msg.ID, "ok": err == "", "error": err})

	return msg.Command
}

func (d *testDevice) report(state map[string]any) {
	d.send(map[string]any{"type": "state", "state": state})
}

var songs = []map[string]any{
	{"id": "c032d12530e3c18d843d13651f9689ac", "title": "Dream On", "durationMs": 268000},
	{"id": "ffffffffffffffffffffffffffffffff", "title": "Other", "durationMs": 200000},
}

func TestRejectedCredentials(t *testing.T) {
	url, _ := startHub(t, Options{Authenticate: func(context.Context, Auth) (string, bool, error) { return "", false, nil }})

	if code := dial(t, url, as("alice"), info("phone", Subsonic, player)).expectClose(); code != CloseUnauthorized {
		t.Fatalf("close code %d, want %d", code, CloseUnauthorized)
	}
}

func TestMediaServerDown(t *testing.T) {
	url, _ := startHub(t, Options{Authenticate: func(context.Context, Auth) (string, bool, error) {
		return "", false, errors.New("connection refused")
	}})

	if code := dial(t, url, as("alice"), info("phone", Subsonic, player)).expectClose(); code != CloseUnavailable {
		t.Fatalf("close code %d, want %d", code, CloseUnavailable)
	}
}

func TestFirstMessageMustBeAValidHello(t *testing.T) {
	url, _ := startHub(t, Options{})

	for name, hello := range map[string]any{
		"not a hello":      map[string]any{"type": "state"},
		"other protocol":   map[string]any{"type": "hello", "protocol": 2, "auth": as("alice"), "device": info("p", Subsonic, player)},
		"no device name":   map[string]any{"type": "hello", "protocol": 1, "auth": as("alice"), "device": map[string]any{"id": "p", "client": "c", "api": "subsonic"}},
		"incomplete auth":  map[string]any{"type": "hello", "protocol": 1, "auth": map[string]any{"scheme": "subsonic"}, "device": info("p", Subsonic, player)},
		"wrong field type": map[string]any{"type": "hello", "protocol": "1"},
	} {
		t.Run(name, func(t *testing.T) {
			ws, _, err := websocket.DefaultDialer.Dial(url, nil)
			if err != nil {
				t.Fatal(err)
			}

			defer ws.Close()
			_ = ws.WriteJSON(hello)
			_, _, err = ws.ReadMessage()
			var closeErr *websocket.CloseError
			if !errors.As(err, &closeErr) || closeErr.Code != CloseBadHello {
				t.Fatalf("got %v, want close %d", err, CloseBadHello)
			}
		})
	}
}

func TestUnknownCapabilitiesAreDropped(t *testing.T) {
	url, _ := startHub(t, Options{})
	pc, _ := join(t, url, as("alice"), info("pc", Subsonic, controller))

	join(t, url, as("alice"), info("tv", Subsonic, player, ActPlay, "dance"))

	if d := pc.expectDevice("tv", func(d Device) bool { return d.Online }); !slices.Equal(d.Capabilities, []Action{ActPlay}) {
		t.Fatalf("capabilities %v", d.Capabilities)
	}
}

func TestRepeatAndShuffleInTheState(t *testing.T) {
	url, _ := startHub(t, Options{})
	tv, _ := join(t, url, as("alice"), info("tv", Subsonic, player, everything...))
	pc, _ := join(t, url, as("alice"), info("pc", Subsonic, controller))

	tv.report(map[string]any{"status": "playing", "positionMs": 0, "queue": songs, "repeat": "all", "shuffle": true})

	if got := pc.expect("state"); got.State.Repeat != RepeatAll || got.State.Shuffle == nil || !*got.State.Shuffle {
		t.Fatalf("state %+v", got.State)
	}

	// A report without them keeps them.
	tv.report(map[string]any{"status": "paused", "positionMs": 1000})
	pc.expect("state")

	_, welcome := join(t, url, as("alice"), info("laptop", Subsonic, controller))
	tvState := welcome.Devices[slices.IndexFunc(welcome.Devices, func(d Device) bool { return d.ID == "tv" })].State
	if tvState.Repeat != RepeatAll || tvState.Shuffle == nil || !*tvState.Shuffle {
		t.Fatalf("the TV's state %+v", tvState)
	}

	tv.report(map[string]any{"status": "paused", "positionMs": 1000, "repeat": "twice"})

	if got := tv.expect("error"); got.Error != "badMessage" {
		t.Fatalf("got %+v", got)
	}
}

func TestUsersSeeOnlyTheirOwnDevices(t *testing.T) {
	url, _ := startHub(t, Options{})

	join(t, url, as("alice"), info("alice-phone", Subsonic, player))
	join(t, url, as("bob"), info("bob-phone", Subsonic, player))

	pc, welcome := join(t, url, as("Alice"), info("alice-pc", Subsonic, controller)) // user names ignore case
	if len(welcome.Devices) != 1 || welcome.Devices[0].ID != "alice-phone" || !welcome.Devices[0].Online {
		t.Fatalf("welcome lists %+v", welcome.Devices)
	}

	join(t, url, as("alice"), info("alice-tv", Subsonic, player))
	pc.expectDevice("alice-tv", func(d Device) bool { return d.Online })
}

func TestStateIsStampedAndTranslated(t *testing.T) {
	c := &clock{now: time.UnixMilli(1_790_000_000_000)}
	url, _ := startHub(t, Options{Now: c.Now})
	phone, _ := join(t, url, as("alice"), info("phone", Jellyfin, player, everything...))
	tv, _ := join(t, url, as("alice"), info("tv", Subsonic, player, everything...))

	phone.report(map[string]any{"status": "playing", "positionMs": 10000, "index": 0, "volume": 80, "queue": songs})

	got := tv.expect("state")
	if got.DeviceID != "phone" || got.State.At != 1_790_000_000_000 || got.State.Status != Playing || got.State.PositionMs != 10000 {
		t.Fatalf("relayed %+v", got)
	}

	if got.State.Queue[0].ID != "5QFKvMsJrd57QE2Le2dKKo" || got.State.Queue[0].Title != "Dream On" {
		t.Fatalf("queue %+v", got.State.Queue)
	}

	// A partial report changes only what it carries; a device joining later gets the merged state.
	c.advance(time.Second)
	phone.report(map[string]any{"status": "paused", "positionMs": 11000})

	if partial := tv.expect("state"); partial.State.Queue != nil || partial.State.Status != Paused {
		t.Fatalf("partial report relayed as %+v", partial.State)
	}

	_, welcome := join(t, url, as("alice"), info("pc", Jellyfin, controller))

	var state *StampedState

	for _, d := range welcome.Devices {
		if d.ID == "phone" {
			state = d.State
		}
	}

	if state == nil || state.Status != Paused || state.PositionMs != 11000 || *state.Volume != 80 || state.Queue[0].ID != songs[0]["id"] {
		t.Fatalf("merged state %+v", state)
	}
}

func TestTheOrderComesAndGoesWithTheQueue(t *testing.T) {
	url, _ := startHub(t, Options{})
	phone, _ := join(t, url, as("alice"), info("phone", Subsonic, player))

	order := func() []int {
		_, welcome := join(t, url, as("alice"), info("pc", Subsonic, controller))

		for _, d := range welcome.Devices {
			if d.ID == "phone" && d.State != nil {
				return d.State.Order
			}
		}

		return nil
	}

	phone.report(map[string]any{"status": "playing", "positionMs": 0, "queue": songs, "shuffle": true, "order": []int{1, 0}})

	if got := order(); !slices.Equal(got, []int{1, 0}) {
		t.Fatalf("order %v", got)
	}

	phone.report(map[string]any{"status": "paused", "positionMs": 1000}) // the queue unchanged

	if got := order(); !slices.Equal(got, []int{1, 0}) {
		t.Fatalf("order %v, after a report without the queue", got)
	}

	phone.report(map[string]any{"status": "paused", "positionMs": 1000, "queue": songs, "shuffle": false})

	if got := order(); got != nil {
		t.Fatalf("order %v, after the queue came without one", got)
	}
}

func TestBadStateReports(t *testing.T) {
	url, _ := startHub(t, Options{})
	phone, _ := join(t, url, as("alice"), info("phone", Subsonic, player))
	pc, _ := join(t, url, as("alice"), info("pc", Subsonic, controller))

	phone.report(map[string]any{"status": "playing"}) // no position

	if msg := phone.expect("error"); msg.Error != "badMessage" {
		t.Fatalf("got %+v", msg)
	}

	// An order that isn't each place of the queue once, or without the queue it orders.
	for _, order := range [][]int{{0, 0}, {0, 2}, {0}} {
		phone.report(map[string]any{"status": "playing", "positionMs": 0, "queue": songs, "shuffle": true, "order": order})

		if msg := phone.expect("error"); msg.Error != "badMessage" {
			t.Fatalf("order %v: got %+v", order, msg)
		}
	}

	phone.report(map[string]any{"status": "playing", "positionMs": 0, "order": []int{1, 0}})

	if msg := phone.expect("error"); msg.Error != "badMessage" {
		t.Fatalf("got %+v", msg)
	}

	pc.report(map[string]any{"status": "playing", "positionMs": 0})

	if msg := pc.expect("error"); msg.Error != "notPlayer" {
		t.Fatalf("got %+v", msg)
	}
}

func TestCommands(t *testing.T) {
	url, _ := startHub(t, Options{})
	tv, _ := join(t, url, as("alice"), info("tv", Subsonic, player, everything...))
	speaker, _ := join(t, url, as("alice"), info("speaker", Subsonic, []Role{RolePlayer}, ActPause))
	pc, _ := join(t, url, as("alice"), info("pc", Subsonic, controller))

	pc.send(map[string]any{"type": "command", "id": "c1", "target": "tv", "command": map[string]any{"action": "seek", "positionMs": 90000}})

	if got := tv.obey(""); got.Action != ActSeek || *got.PositionMs != 90000 {
		t.Fatalf("the TV got %+v", got)
	}

	if r := pc.expect("result"); r.Re != "c1" || !r.OK {
		t.Fatalf("result %+v", r)
	}

	pc.send(map[string]any{"type": "command", "id": "r", "target": "tv", "command": map[string]any{"action": "setRepeat", "repeat": "one"}})

	if got := tv.obey(""); got.Action != ActSetRepeat || got.Repeat != RepeatOne {
		t.Fatalf("the TV got %+v", got)
	}

	pc.expect("result")
	pc.send(map[string]any{"type": "command", "id": "s", "target": "tv", "command": map[string]any{"action": "setShuffle", "shuffle": false}})

	if got := tv.obey(""); got.Action != ActSetShuffle || got.Shuffle == nil || *got.Shuffle {
		t.Fatalf("the TV got %+v", got)
	}

	pc.expect("result")

	pc.send(map[string]any{"type": "command", "id": "q", "target": "tv", "command": map[string]any{
		"action": "setQueue", "queue": songs, "index": 1, "positionMs": 0, "play": true,
		"repeat": "one", "shuffle": true, "order": []int{1, 0},
	}})

	if got := tv.obey(""); got.Action != ActSetQueue || got.Repeat != RepeatOne || got.Shuffle == nil || !*got.Shuffle ||
		!slices.Equal(got.Order, []int{1, 0}) {
		t.Fatalf("the TV got %+v", got)
	}

	pc.expect("result")

	pc.send(map[string]any{"type": "command", "id": "j", "target": "tv", "command": map[string]any{"action": "jump", "index": 2}})

	if got := tv.obey(""); got.Action != ActJump || got.Index == nil || *got.Index != 2 {
		t.Fatalf("the TV got %+v", got)
	}

	pc.expect("result")

	pc.send(map[string]any{"type": "command", "id": "c2", "target": "tv", "command": map[string]any{"action": "next"}})
	tv.obey("no such track")

	if r := pc.expect("result"); r.OK || r.Error != "no such track" {
		t.Fatalf("result %+v", r)
	}

	for _, c := range []struct {
		target  string
		command map[string]any
		want    string
	}{
		{"nowhere", map[string]any{"action": "play"}, "unknownDevice"},
		{"pc", map[string]any{"action": "play"}, "notPlayer"},
		{"speaker", map[string]any{"action": "next"}, "unsupported"},
		{"tv", map[string]any{"action": "seek"}, "badMessage"},
		{"tv", map[string]any{"action": "setVolume", "volume": 101}, "badMessage"},
		{"tv", map[string]any{"action": "setRepeat", "repeat": "twice"}, "badMessage"},
		{"speaker", map[string]any{"action": "setRepeat", "repeat": "all"}, "unsupported"},
		{"tv", map[string]any{"action": "setShuffle"}, "badMessage"},
		{"tv", map[string]any{"action": "jump"}, "badMessage"},
		{"tv", map[string]any{"action": "jump", "index": -1}, "badMessage"},
		{"speaker", map[string]any{"action": "jump", "index": 0}, "unsupported"},
		{"tv", map[string]any{"action": "setQueue", "queue": songs, "index": 0, "positionMs": 0, "play": true, "repeat": "twice"}, "badMessage"},
		{"tv", map[string]any{"action": "setQueue", "queue": songs, "index": 0, "positionMs": 0, "play": true, "shuffle": true, "order": []int{1, 1}}, "badMessage"},
		{"tv", map[string]any{"action": "setQueue", "queue": songs, "index": 0, "positionMs": 0, "play": true, "order": []int{1, 0}}, "badMessage"},
		{"tv", map[string]any{"action": "addToQueue", "queue": songs}, "badMessage"},
		{"tv", map[string]any{"action": "addToQueue", "queue": []any{}, "next": true}, "badMessage"},
		{"speaker", map[string]any{"action": "addToQueue", "queue": songs, "next": true}, "unsupported"},
		{"tv", map[string]any{"action": "moveInQueue", "index": 1}, "badMessage"},
		{"tv", map[string]any{"action": "moveInQueue", "to": 0}, "badMessage"},
		{"tv", map[string]any{"action": "moveInQueue", "index": 1, "to": -1}, "badMessage"},
		{"speaker", map[string]any{"action": "moveInQueue", "index": 1, "to": 0}, "unsupported"},
		{"tv", map[string]any{"action": "removeFromQueue"}, "badMessage"},
		{"tv", map[string]any{"action": "removeFromQueue", "index": -1}, "badMessage"},
		{"speaker", map[string]any{"action": "removeFromQueue", "index": 1}, "unsupported"},
	} {
		pc.send(map[string]any{"type": "command", "id": "x", "target": c.target, "command": c.command})

		if r := pc.expect("result"); r.OK || r.Error != c.want {
			t.Errorf("%s %v: got %+v, want %s", c.target, c.command, r, c.want)
		}
	}

drain:
	for {
		select {
		case msg := <-speaker.msgs:
			if msg.Type == "command" {
				t.Fatal("the speaker got a command it doesn't obey")
			}
		default:
			break drain
		}
	}
}

func TestTransfer(t *testing.T) {
	c := &clock{now: time.UnixMilli(1_790_000_000_000)}
	url, _ := startHub(t, Options{Now: c.Now})
	phone, _ := join(t, url, as("alice"), info("phone", Jellyfin, player, everything...))
	tv, _ := join(t, url, as("alice"), info("tv", Subsonic, player, everything...))
	pc, _ := join(t, url, as("alice"), info("pc", Subsonic, controller))

	phone.report(map[string]any{
		"status": "playing", "positionMs": 30000, "index": 1, "queue": songs,
		"repeat": "all", "shuffle": true, "order": []int{1, 0},
	})
	pc.expect("state")
	c.advance(200 * time.Millisecond)

	pc.send(map[string]any{"type": "transfer", "id": "t1", "from": "phone", "to": "tv"})

	got := tv.obey("")
	if got.Action != ActSetQueue || *got.Index != 1 || *got.PositionMs != 30200 || !*got.Play {
		t.Fatalf("the TV got %+v", got)
	}

	// In the modes it played in, shuffled in the same order.
	if got.Repeat != RepeatAll || got.Shuffle == nil || !*got.Shuffle || !slices.Equal(got.Order, []int{1, 0}) {
		t.Fatalf("the TV got the modes %q, %v, %v", got.Repeat, got.Shuffle, got.Order)
	}

	if got.Queue[0].ID != "5QFKvMsJrd57QE2Le2dKKo" || got.Queue[1].ID != "7N42dgm5tFLK9N8MT7fHC7" {
		t.Fatalf("queue %+v", got.Queue)
	}

	// The music has left the phone: it stops, rather than stay paused with a queue no one plays.
	if stopped := phone.obey(""); stopped.Action != ActStop {
		t.Fatalf("the phone got %+v", stopped)
	}

	if r := pc.expect("result"); r.Re != "t1" || !r.OK {
		t.Fatalf("result %+v", r)
	}

	pc.send(map[string]any{"type": "transfer", "id": "t2", "from": "pc", "to": "tv"})

	if r := pc.expect("result"); r.Error != "nothingToTransfer" {
		t.Fatalf("result %+v", r)
	}
}

func TestAddToQueue(t *testing.T) {
	url, _ := startHub(t, Options{})
	tv, _ := join(t, url, as("alice"), info("tv", Subsonic, player, everything...))
	phone, _ := join(t, url, as("alice"), info("phone", Jellyfin, controller))

	// The tracks reach the player in its own API, with the place they go.
	phone.send(map[string]any{"type": "command", "id": "a1", "target": "tv", "command": map[string]any{"action": "addToQueue", "queue": songs, "next": false}})

	got := tv.obey("")
	if got.Action != ActAddToQueue || got.Next == nil || *got.Next || got.Index != nil || got.Play != nil {
		t.Fatalf("the TV got %+v", got)
	}

	if len(got.Queue) != 2 || got.Queue[0].ID != "5QFKvMsJrd57QE2Le2dKKo" || got.Queue[1].ID != "7N42dgm5tFLK9N8MT7fHC7" {
		t.Fatalf("queue %+v", got.Queue)
	}

	if r := phone.expect("result"); r.Re != "a1" || !r.OK {
		t.Fatalf("result %+v", r)
	}

	phone.send(map[string]any{"type": "command", "id": "a2", "target": "tv", "command": map[string]any{"action": "addToQueue", "queue": songs[:1], "next": true}})

	if got := tv.obey(""); got.Next == nil || !*got.Next || len(got.Queue) != 1 {
		t.Fatalf("the TV got %+v", got)
	}

	phone.expect("result")
}

func TestMoveAndRemoveInQueue(t *testing.T) {
	url, _ := startHub(t, Options{})
	tv, _ := join(t, url, as("alice"), info("tv", Subsonic, player, everything...))
	phone, _ := join(t, url, as("alice"), info("phone", Jellyfin, controller))

	// The places reach the player as they were sent, and nothing else.
	phone.send(map[string]any{"type": "command", "id": "m1", "target": "tv", "command": map[string]any{"action": "moveInQueue", "index": 2, "to": 0, "queue": songs, "next": true}})

	got := tv.obey("")
	if got.Action != ActMoveInQueue || got.Index == nil || *got.Index != 2 || got.To == nil || *got.To != 0 || got.Queue != nil || got.Next != nil {
		t.Fatalf("the TV got %+v", got)
	}

	if r := phone.expect("result"); r.Re != "m1" || !r.OK {
		t.Fatalf("result %+v", r)
	}

	phone.send(map[string]any{"type": "command", "id": "m2", "target": "tv", "command": map[string]any{"action": "removeFromQueue", "index": 1, "to": 3}})

	if got := tv.obey(""); got.Action != ActRemoveFromQueue || got.Index == nil || *got.Index != 1 || got.To != nil {
		t.Fatalf("the TV got %+v", got)
	}

	phone.expect("result")

	// The player's own error reaches the controller as it is.
	phone.send(map[string]any{"type": "command", "id": "m3", "target": "tv", "command": map[string]any{"action": "removeFromQueue", "index": 0}})
	tv.obey("current track")

	if r := phone.expect("result"); r.OK || r.Error != "current track" {
		t.Fatalf("result %+v", r)
	}
}

func TestTransferLeavesThePausedSourceIdleToo(t *testing.T) {
	url, _ := startHub(t, Options{})
	phone, _ := join(t, url, as("alice"), info("phone", Subsonic, player, everything...))
	tv, _ := join(t, url, as("alice"), info("tv", Subsonic, player, everything...))

	phone.report(map[string]any{"status": "paused", "positionMs": 5000, "queue": songs})
	tv.expect("state")
	phone.send(map[string]any{"type": "transfer", "id": "t", "from": "phone", "to": "tv", "play": true})
	tv.obey("")

	if stopped := phone.obey(""); stopped.Action != ActStop {
		t.Fatalf("the phone got %+v", stopped)
	}

	phone.expect("result")
}

func TestADeviceWithoutStopIsPausedInstead(t *testing.T) {
	url, _ := startHub(t, Options{})
	old := []Action{ActPlay, ActPause, ActSetQueue}
	phone, _ := join(t, url, as("alice"), info("phone", Subsonic, player, old...))
	tv, _ := join(t, url, as("alice"), info("tv", Subsonic, player, everything...))

	phone.report(map[string]any{"status": "playing", "positionMs": 0, "queue": songs})
	tv.expect("state")
	tv.report(map[string]any{"status": "playing", "positionMs": 0, "queue": songs})

	if msg := phone.expect("command"); msg.Command.Action != ActPause {
		t.Fatalf("one device at a time: the phone got %+v", msg.Command)
	}
}

func TestContinueHereFromAnOfflineDevice(t *testing.T) {
	url, _ := startHub(t, Options{})
	phone, _ := join(t, url, as("alice"), info("phone", Subsonic, player, everything...))
	tv, _ := join(t, url, as("alice"), info("tv", Subsonic, player, everything...))

	phone.report(map[string]any{"status": "paused", "positionMs": 5000, "queue": songs[:1]})
	tv.expect("state")
	_ = phone.ws.Close()
	tv.expectDevice("phone", func(d Device) bool { return !d.Online && d.State != nil && d.State.PositionMs == 5000 })

	tv.send(map[string]any{"type": "transfer", "id": "t", "from": "phone", "to": "tv", "play": false})

	if got := tv.obey(""); *got.PositionMs != 5000 || *got.Play || got.Queue[0].ID != songs[0]["id"] {
		t.Fatalf("the TV got %+v", got)
	}

	if r := tv.expect("result"); !r.OK {
		t.Fatalf("result %+v", r)
	}
}

func TestTransferWithoutASourceTakesTheLastPlayback(t *testing.T) {
	c := &clock{now: time.UnixMilli(1_790_000_000_000)}
	url, _ := startHub(t, Options{Now: c.Now})
	phone, _ := join(t, url, as("alice"), info("phone", Jellyfin, player, everything...))
	tv, _ := join(t, url, as("alice"), info("tv", Subsonic, player, everything...))
	pc, _ := join(t, url, as("alice"), info("pc", Subsonic, controller))

	stateFrom := func(d *testDevice, id string) {
		t.Helper()

		for d.expect("state").DeviceID != id {
		}
	}

	pc.send(map[string]any{"type": "transfer", "id": "t0", "to": "tv"})

	if r := pc.expect("result"); r.Error != "nothingToTransfer" {
		t.Fatalf("with no last playback: %+v", r)
	}

	phone.report(map[string]any{"status": "playing", "positionMs": 30000, "index": 1, "queue": songs, "repeat": "all"})
	stateFrom(pc, "phone")
	c.advance(200 * time.Millisecond)

	// The phone holds it: its queue moves from where it is now, as if from named it.
	pc.send(map[string]any{"type": "transfer", "id": "t1", "to": "tv"})

	got := tv.obey("")
	if got.Action != ActSetQueue || *got.Index != 1 || *got.PositionMs != 30200 || !*got.Play || got.Repeat != RepeatAll {
		t.Fatalf("the TV got %+v", got)
	}

	if got.Queue[0].ID != "5QFKvMsJrd57QE2Le2dKKo" {
		t.Fatalf("queue %+v", got.Queue)
	}

	if stopped := phone.obey(""); stopped.Action != ActStop {
		t.Fatalf("the phone got %+v", stopped)
	}

	if r := pc.expect("result"); r.Re != "t1" || !r.OK {
		t.Fatalf("result %+v", r)
	}

	phone.report(map[string]any{"status": "stopped", "positionMs": 30200})
	stateFrom(pc, "phone")
	tv.report(map[string]any{"status": "playing", "positionMs": 30200, "index": 1, "queue": songs})
	stateFrom(pc, "tv")

	// The TV holds it now, so the music is already there: a result, and no command.
	pc.send(map[string]any{"type": "transfer", "id": "t2", "to": "tv"})

	if r := pc.expect("result"); r.Re != "t2" || !r.OK {
		t.Fatalf("result %+v", r)
	}

	tv.report(map[string]any{"status": "paused", "positionMs": 40000})
	stateFrom(pc, "tv")
	pc.send(map[string]any{"type": "transfer", "id": "t3", "to": "tv", "play": false})

	if r := pc.expect("result"); r.Re != "t3" || !r.OK {
		t.Fatalf("result %+v", r)
	}

	// Paused there, it only needs to play.
	pc.send(map[string]any{"type": "transfer", "id": "t4", "to": "tv"})

	if got := tv.obey(""); got.Action != ActPlay {
		t.Fatalf("the TV got %+v", got)
	}

	if r := pc.expect("result"); r.Re != "t4" || !r.OK {
		t.Fatalf("result %+v", r)
	}
}

func TestTransferWithoutASourceAfterARestart(t *testing.T) {
	c := &clock{now: time.UnixMilli(1_790_000_000_000)}
	path := filepath.Join(t.TempDir(), "last.json")
	url, h := startHub(t, Options{Now: c.Now, StatePath: path})
	phone, _ := join(t, url, as("alice"), info("phone", Jellyfin, player, everything...))

	phone.report(map[string]any{"status": "playing", "positionMs": 30000, "index": 1, "queue": songs})
	time.Sleep(50 * time.Millisecond) // the report reaches the hub
	c.advance(10 * time.Second)
	h.Close()

	if code := phone.expectClose(); code != CloseGoingAway {
		t.Fatalf("the phone got %d", code)
	}

	// The hub went down with the phone playing. Back an hour later, it has no device, and the last
	// playback's clock stopped where the phone had got to as the hub went down.
	c.advance(time.Hour)

	url2, _ := startHub(t, Options{Now: c.Now, StatePath: path})
	tv, welcome := join(t, url2, as("alice"), info("tv", Subsonic, player, everything...))

	if last := welcome.LastPlayback; last == nil || last.State.Status != Paused || last.State.PositionMs != 40000 {
		t.Fatalf("last playback after a restart %+v", last)
	}

	tv.send(map[string]any{"type": "transfer", "id": "t1", "from": "phone", "to": "tv"})

	if r := tv.expect("result"); r.Error != "unknownDevice" {
		t.Fatalf("result %+v", r)
	}

	// Without a source, the last playback itself moves, with no device to stop.
	tv.send(map[string]any{"type": "transfer", "id": "t2", "to": "tv"})

	got := tv.obey("")
	if got.Action != ActSetQueue || *got.Index != 1 || *got.PositionMs != 40000 || !*got.Play {
		t.Fatalf("the TV got %+v", got)
	}

	if got.Queue[0].ID != "5QFKvMsJrd57QE2Le2dKKo" {
		t.Fatalf("queue %+v", got.Queue)
	}

	if r := tv.expect("result"); r.Re != "t2" || !r.OK {
		t.Fatalf("result %+v", r)
	}
}

func TestCloseTellsTheDevicesAndTurnsNewOnesAway(t *testing.T) {
	url, h := startHub(t, Options{})
	phone, _ := join(t, url, as("alice"), info("phone", Subsonic, player, everything...))
	pc, _ := join(t, url, as("bob"), info("pc", Subsonic, controller))

	start := time.Now()

	h.Close()

	// The devices answered the close frames, so Close didn't wait them out.
	if waited := time.Since(start); waited >= closeWait {
		t.Fatalf("Close took %v", waited)
	}

	for _, d := range []*testDevice{phone, pc} {
		if code := d.expectClose(); code != CloseGoingAway {
			t.Fatalf("closed with %d", code)
		}
	}

	if code := dial(t, url, as("alice"), info("tv", Subsonic, player, everything...)).expectClose(); code != CloseGoingAway {
		t.Fatalf("a hello after Close: %d", code)
	}
}

func TestLastPlaybackStopsWhereItWasAfterACrash(t *testing.T) {
	c := &clock{now: time.UnixMilli(1_790_000_000_000)}
	path := filepath.Join(t.TempDir(), "last.json")
	// What a hub that died with the TV playing left: no Close, so nobody let go of it.
	last := map[string]any{"alice": map[string]any{
		"deviceId": "tv", "deviceName": "tv", "api": "subsonic",
		"state": map[string]any{"status": "playing", "positionMs": 30000, "at": c.Now().UnixMilli(), "queue": songs},
	}}
	data, _ := json.Marshal(last)

	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}

	c.advance(time.Hour)

	url, _ := startHub(t, Options{Now: c.Now, StatePath: path})
	_, welcome := join(t, url, as("alice"), info("phone", Subsonic, controller))

	// Where the last report put it: how long it played on, nobody can tell.
	if got := welcome.LastPlayback; got == nil || got.DeviceID != "" || got.State.Status != Paused || got.State.PositionMs != 30000 {
		t.Fatalf("last playback after a crash %+v", got)
	}
}

func TestReconnectReplacesTheOldConnection(t *testing.T) {
	url, _ := startHub(t, Options{})
	pc, _ := join(t, url, as("alice"), info("pc", Subsonic, controller))
	old, _ := join(t, url, as("alice"), info("phone", Subsonic, player, everything...))

	pc.expectDevice("phone", func(d Device) bool { return d.Online })

	phone, _ := join(t, url, as("alice"), info("phone", Subsonic, player, everything...))

	if code := old.expectClose(); code != CloseReplaced {
		t.Fatalf("old connection closed with %d", code)
	}

	pc.send(map[string]any{"type": "command", "id": "c", "target": "phone", "command": map[string]any{"action": "play"}})
	phone.obey("")

	if r := pc.expect("result"); !r.OK {
		t.Fatalf("result %+v", r)
	}

	// The old connection's close must not have marked the device offline.
quiet:
	for {
		select {
		case msg := <-pc.msgs:
			if msg.Type == "device" && !msg.Device.Online {
				t.Fatal("the device went offline")
			}
		case <-time.After(100 * time.Millisecond):
			break quiet
		}
	}
}

func TestCommandTimeoutAndDisconnect(t *testing.T) {
	url, _ := startHub(t, Options{CommandTimeout: 100 * time.Millisecond})
	stuck, _ := join(t, url, as("alice"), info("stuck", Subsonic, player, everything...))
	pc, _ := join(t, url, as("alice"), info("pc", Subsonic, controller))

	pc.send(map[string]any{"type": "command", "id": "late", "target": "stuck", "command": map[string]any{"action": "play"}})

	late := stuck.expect("command")

	if r := pc.expect("result"); r.Error != "timeout" {
		t.Fatalf("result %+v", r)
	}

	stuck.send(map[string]any{"type": "result", "re": late.ID, "ok": true}) // ignored

	// A player that goes away fails its pending commands at once, without waiting for the timeout.
	pc.send(map[string]any{"type": "command", "id": "gone", "target": "stuck", "command": map[string]any{"action": "play"}})
	stuck.expect("command")
	_ = stuck.ws.Close()

	if r := pc.expect("result"); r.Error != "offline" {
		t.Fatalf("result %+v", r)
	}
}

func TestSweepForgetsOldOfflineDevices(t *testing.T) {
	c := &clock{now: time.UnixMilli(1_790_000_000_000)}
	url, h := startHub(t, Options{Now: c.Now, OfflineTTL: time.Hour})
	phone, _ := join(t, url, as("alice"), info("phone", Subsonic, player))
	pc, _ := join(t, url, as("alice"), info("pc", Subsonic, controller))
	_ = phone.ws.Close()
	pc.expectDevice("phone", func(d Device) bool { return !d.Online })

	c.advance(59 * time.Minute)
	h.Sweep()
	c.advance(2 * time.Minute)
	h.Sweep()

	if msg := pc.expect("gone"); msg.DeviceID != "phone" {
		t.Fatalf("got %+v", msg)
	}
}

func TestInfoEndpoint(t *testing.T) {
	h := New(Options{Authenticate: byUsername})

	for _, path := range []string{"/v1/info", "/connect/v1/info"} {
		w := httptest.NewRecorder()

		h.Handler(map[string]any{"server": "navidrome", "protocol": "ignored"}).ServeHTTP(w, httptest.NewRequest("GET", path, nil))

		if w.Code != 200 || w.Body.String() != `{"protocol":"segue","server":"navidrome","versions":[1]}` {
			t.Errorf("%s: %d %s", path, w.Code, w.Body)
		}
	}

	w := httptest.NewRecorder()

	h.Handler(nil).ServeHTTP(w, httptest.NewRequest("GET", "/connectx/v1/info", nil))

	if w.Code != 404 {
		t.Errorf("/connectx/v1/info: %d", w.Code)
	}
}

func TestInfoThatIsntJSON(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Error("Handler took info that doesn't encode as JSON")
		}
	}()
	New(Options{Authenticate: byUsername}).Handler(map[string]any{"server": func() {}})
}

func TestRoutes(t *testing.T) {
	h := New(Options{Authenticate: byUsername})

	for _, tc := range []struct {
		method, path string
		code         int
		allow        string
	}{
		{"HEAD", "/v1/info", 200, ""},
		{"HEAD", "/connect/v1/info", 200, ""},
		{"POST", "/v1/info", 405, "GET, HEAD"},
		{"POST", "/connect/v1/info", 405, "GET, HEAD"},
		{"GET", "/v1/other", 404, ""},
		{"GET", "/connect/connect/v1/info", 404, ""}, // the prefix is taken off once
		{"GET", "/", 404, ""},
	} {
		w := httptest.NewRecorder()

		h.Handler(nil).ServeHTTP(w, httptest.NewRequest(tc.method, tc.path, nil))

		if w.Code != tc.code || w.Header().Get("Allow") != tc.allow {
			t.Errorf("%s %s: %d, Allow %q", tc.method, tc.path, w.Code, w.Header().Get("Allow"))
		}
	}

	// The WebSocket under /connect/, where it sits on the media server's origin.
	url, _ := startHub(t, Options{})

	join(t, strings.Replace(url, "/v1/ws", "/connect/v1/ws", 1), as("alice"), info("tv", Subsonic, player))
}

func TestLastPlayback(t *testing.T) {
	c := &clock{now: time.UnixMilli(1_790_000_000_000)}
	path := filepath.Join(t.TempDir(), "last.json")
	url, h := startHub(t, Options{Now: c.Now, StatePath: path})
	phone, _ := join(t, url, as("alice"), info("phone", Jellyfin, player, everything...))
	tv, _ := join(t, url, as("alice"), info("tv", Subsonic, player, everything...))

	stateFrom := func(d *testDevice, id string) {
		t.Helper()

		for d.expect("state").DeviceID != id {
		}
	}

	phone.report(map[string]any{"status": "playing", "positionMs": 30000, "index": 1, "queue": songs})
	stateFrom(tv, "phone")

	// A paused device with a queue of its own doesn't take the last playback over, and an app that
	// opens empty doesn't wipe it.
	tv.report(map[string]any{"status": "paused", "positionMs": 0, "queue": songs[:1]})
	stateFrom(phone, "tv")

	pc, _ := join(t, url, as("alice"), info("pc", Subsonic, player, everything...))

	pc.report(map[string]any{"status": "stopped", "positionMs": 0, "queue": []any{}})
	stateFrom(tv, "pc")

	// The phone goes away while playing: its position freezes where it got to, and the phone lets
	// go of it. The name still says where it played.
	c.advance(10 * time.Second)
	_ = phone.ws.Close()
	tv.expectDevice("phone", func(d Device) bool { return !d.Online })

	_, welcome := join(t, url, as("alice"), info("laptop", Subsonic, controller))
	last := welcome.LastPlayback
	if last == nil || last.DeviceID != "" || last.DeviceName != "phone" {
		t.Fatalf("last playback %+v", last)
	}

	if last.State.Status != Paused || last.State.PositionMs != 40000 || *last.State.Index != 1 {
		t.Fatalf("state %+v", last.State.PlayerState)
	}

	if last.State.Queue[0].ID != "5QFKvMsJrd57QE2Le2dKKo" {
		t.Fatalf("queue not in the Subsonic ids: %+v", last.State.Queue)
	}

	// It survives a restart, and reaches each device in its own API.
	h.Close()

	url2, _ := startHub(t, Options{StatePath: path})
	_, welcome = join(t, url2, as("Alice"), info("laptop", Jellyfin, controller))

	if last := welcome.LastPlayback; last == nil || last.State.PositionMs != 40000 || last.State.Queue[0].ID != songs[0]["id"] {
		t.Fatalf("after a restart: %+v", last)
	}
}

func TestOfflineDeviceStopsPlaying(t *testing.T) {
	c := &clock{now: time.UnixMilli(1_790_000_000_000)}
	url, _ := startHub(t, Options{Now: c.Now})
	phone, _ := join(t, url, as("alice"), info("phone", Subsonic, player, everything...))
	tv, _ := join(t, url, as("alice"), info("tv", Subsonic, player, everything...))

	phone.report(map[string]any{"status": "playing", "positionMs": 30000, "queue": songs})
	tv.expect("state")

	// Offline, it is paused where it had got to, and comes back paused: not as a device that has
	// just started playing, before its first report.
	c.advance(10 * time.Second)
	_ = phone.ws.Close()
	tv.expectDevice("phone", func(d Device) bool {
		return !d.Online && d.State.Status == Paused && d.State.PositionMs == 40000
	})
	join(t, url, as("alice"), info("phone", Subsonic, player, everything...))
	tv.expectDevice("phone", func(d Device) bool { return d.Online && d.State.Status == Paused })
}

func TestLastPlaybackMovesOnlyByPlaying(t *testing.T) {
	url, _ := startHub(t, Options{})
	phone, _ := join(t, url, as("alice"), info("phone", Subsonic, player, everything...))
	tv, _ := join(t, url, as("alice"), info("tv", Subsonic, player, everything...))

	lastOn := func() string {
		t.Helper()
		time.Sleep(50 * time.Millisecond) // the report before reaches the hub

		_, welcome := join(t, url, as("alice"), info("pc", Subsonic, controller))
		if welcome.LastPlayback == nil {
			return ""
		}

		return welcome.LastPlayback.DeviceID
	}

	phone.report(map[string]any{"status": "playing", "positionMs": 0, "queue": songs})
	tv.expect("state")

	// The phone closes, and the TV loads its music paused, as an app does when it opens or when the
	// device it followed closes: that isn't playing, so nobody holds it. Nor does the phone, back
	// and loading it again.
	_ = phone.ws.Close()
	tv.expectDevice("phone", func(d Device) bool { return !d.Online })
	tv.report(map[string]any{"status": "paused", "positionMs": 0, "queue": songs})

	if got := lastOn(); got != "" {
		t.Fatalf("last playback on %q after the TV loaded it", got)
	}

	phone, _ = join(t, url, as("alice"), info("phone", Subsonic, player, everything...))
	phone.report(map[string]any{"status": "paused", "positionMs": 0, "queue": songs})

	if got := lastOn(); got != "" {
		t.Fatalf("last playback on %q after the phone came back", got)
	}

	tv.report(map[string]any{"status": "playing", "positionMs": 0, "queue": songs})

	if got := lastOn(); got != "tv" {
		t.Fatalf("last playback on %q after the TV played", got)
	}
}

func TestLastPlaybackStaysWithAPausedDeviceThatIsOn(t *testing.T) {
	url, _ := startHub(t, Options{})
	tv, _ := join(t, url, as("alice"), info("tv", Subsonic, player, everything...))

	tv.report(map[string]any{"status": "playing", "positionMs": 0, "queue": songs})
	tv.report(map[string]any{"status": "paused", "positionMs": 5000})
	time.Sleep(50 * time.Millisecond)

	_, welcome := join(t, url, as("alice"), info("phone", Subsonic, controller))

	if last := welcome.LastPlayback; last == nil || last.DeviceID != "tv" || last.State.PositionMs != 5000 {
		t.Fatalf("last playback %+v", last)
	}
}

func TestLastPlaybackHasNoHolderAfterARestart(t *testing.T) {
	path := filepath.Join(t.TempDir(), "last.json")
	url, h := startHub(t, Options{StatePath: path})
	tv, _ := join(t, url, as("alice"), info("tv", Subsonic, player, everything...))

	tv.report(map[string]any{"status": "playing", "positionMs": 0, "queue": songs})
	tv.report(map[string]any{"status": "paused", "positionMs": 5000})
	time.Sleep(50 * time.Millisecond)
	h.Close()

	url2, _ := startHub(t, Options{StatePath: path})
	_, welcome := join(t, url2, as("alice"), info("phone", Subsonic, controller))

	if last := welcome.LastPlayback; last == nil || last.DeviceID != "" || last.DeviceName != "tv" || last.State.PositionMs != 5000 {
		t.Fatalf("last playback after a restart %+v", last)
	}
}

func TestLastPlaybackFollowsWhoPlays(t *testing.T) {
	url, _ := startHub(t, Options{})
	phone, _ := join(t, url, as("alice"), info("phone", Subsonic, player, everything...))
	tv, _ := join(t, url, as("alice"), info("tv", Subsonic, player, everything...))

	phone.report(map[string]any{"status": "playing", "positionMs": 0, "queue": songs})
	tv.expect("state")
	tv.report(map[string]any{"status": "playing", "positionMs": 5000, "queue": songs[1:]})
	phone.expect("state")

	_, welcome := join(t, url, as("alice"), info("pc", Subsonic, controller))

	if last := welcome.LastPlayback; last == nil || last.DeviceID != "tv" || len(last.State.Queue) != 1 {
		t.Fatalf("last playback %+v", last)
	}
}

func TestStartingToPlayStopsTheOthers(t *testing.T) {
	url, _ := startHub(t, Options{})
	phone, _ := join(t, url, as("alice"), info("phone", Subsonic, player, everything...))
	tv, _ := join(t, url, as("alice"), info("tv", Subsonic, player, everything...))
	speaker, _ := join(t, url, as("alice"), info("speaker", Subsonic, player, everything...))

	stateFrom := func(d *testDevice, id string) {
		t.Helper()

		for d.expect("state").DeviceID != id {
		}
	}

	noCommand := func(d *testDevice) {
		t.Helper()

		deadline := time.After(200 * time.Millisecond)

		for {
			select {
			case msg := <-d.msgs:
				if msg.Type == "command" {
					t.Fatalf("%v got %+v", d.ws.LocalAddr(), msg.Command)
				}
			case <-deadline:
				return
			}
		}
	}

	// One at a time: from two connections, the reports could reach the TV in either order.
	phone.report(map[string]any{"status": "playing", "positionMs": 0, "queue": songs})
	stateFrom(tv, "phone")
	speaker.report(map[string]any{"status": "paused", "positionMs": 0, "queue": songs})
	stateFrom(tv, "speaker")

	// The TV starts playing: the phone, which plays, stops; the paused speaker is left alone.
	tv.report(map[string]any{"status": "playing", "positionMs": 0, "queue": songs})

	msg := phone.expect("command")
	if msg.Command.Action != ActStop || msg.From != "tv" {
		t.Fatalf("the phone got %+v from %q", msg.Command, msg.From)
	}

	phone.send(map[string]any{"type": "result", "re": msg.ID, "ok": true})
	noCommand(speaker)

	// More reports from a device that already plays (a new track, say) pause nobody again.
	tv.report(map[string]any{"status": "playing", "positionMs": 0, "index": 1})
	noCommand(phone)
}
