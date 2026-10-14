package hub

import (
	"cmp"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"slices"
	"strings"
	"sync"
	"time"
)

// Options configures a Hub. Authenticate is required.
type Options struct {
	Authenticate Authenticator
	// Translate expresses ids across APIs. Nil means they never are (NoTranslation).
	Translate IDTranslator
	// Logger defaults to discarding everything.
	Logger *slog.Logger
	// Now defaults to time.Now.
	Now func() time.Time
	// HelloTimeout is how long a new connection has to send its hello. Default 10 s.
	HelloTimeout time.Duration
	// CommandTimeout is how long to wait for a player to answer a command. Default 10 s.
	CommandTimeout time.Duration
	// OfflineTTL is how long an offline device, with its last state, stays listed. Default 24 h.
	OfflineTTL time.Duration
	// StatePath is a file where each user's last playback is kept across restarts. Empty keeps it
	// in memory only. Call Close at shutdown so the last change gets written.
	StatePath string
	// Report tells the media server what each device plays (SPEC.md, section 12). Nil reports
	// nothing.
	Report Reporter
}

// Conn is the hub's side of one connection. Send and Close must not block: the hub calls them
// while holding its lock. Close sends a close frame after whatever was already sent.
//
// A Conn may also have a Probe method, which must not block either. The hub calls it as it sends
// a player a command, and it drops the connection if the device doesn't answer within a few
// seconds (a ping, say): a player that went away, out of reach with nothing closed, fails the
// command as offline and goes offline for the others, without waiting for the timeout or the next
// ping (SPEC.md, section 9).
type Conn interface {
	Send(msg any)
	Close(code int, reason string)
}

// prober is a Conn with a Probe method.
type prober interface {
	Probe()
}

// Hub keeps the devices of each user, relays their state to the user's other devices and routes
// commands between them. Only each user's last playback can go to disk (Options.StatePath): after
// a restart, devices just reconnect.
type Hub struct {
	opts Options
	log  *slog.Logger

	mu      sync.Mutex
	users   map[string]map[string]*entry // user → device id → device
	pending map[string]*pending          // command id → command waiting for its answer
	last    map[string]*lastPlayback     // user → last playback
	store   *store                       // nil without StatePath
	reports *reportQueue                 // nil without Report
	// stopReportingAgain stops the ticker that calls reportAgain; nil without Report.
	stopReportingAgain func()
	closing            bool          // Close has started: devices that say hello are turned away
	drained            chan struct{} // closed once no device is online, while Close waits for that
}

// closeWait is how long Close waits for the devices to answer its close frames.
const closeWait = 2 * time.Second

type entry struct {
	user     string
	info     DeviceInfo
	auth     Auth // while online, to report its playback with (SPEC.md, section 12)
	conn     Conn // nil while offline
	state    *StampedState
	lastSeen time.Time
	// reported is what the media server last heard of its playback, at hub time reportedAt.
	reported   *Playback
	reportedAt int64
}

type outcome struct {
	ok  bool
	err string
}

type pending struct {
	target *entry
	done   chan outcome // buffered: finishing never blocks
}

// New returns a hub configured by opts, and panics if opts.Authenticate is nil. Call Close at
// shutdown, which tells the devices, and finishes the work the hub does in the background with a
// StatePath or a Report.
func New(opts Options) *Hub {
	if opts.Authenticate == nil {
		panic("hub: Options.Authenticate is required")
	}

	if opts.Translate == nil {
		opts.Translate = NoTranslation
	}

	if opts.Now == nil {
		opts.Now = time.Now
	}

	opts.HelloTimeout = cmp.Or(opts.HelloTimeout, 10*time.Second)
	opts.CommandTimeout = cmp.Or(opts.CommandTimeout, 10*time.Second)
	opts.OfflineTTL = cmp.Or(opts.OfflineTTL, 24*time.Hour)
	log := cmp.Or(opts.Logger, slog.New(slog.NewTextHandler(io.Discard, nil)))
	h := &Hub{opts: opts, log: log, users: map[string]map[string]*entry{}, pending: map[string]*pending{}}
	h.last = map[string]*lastPlayback{}

	if opts.StatePath != "" {
		h.store, h.last = openStore(opts.StatePath, log)

		// No device is connected yet, so none holds a last playback, and its clock has stopped
		// (SPEC.md, section 7): where the last report put it, since how long it played on is unknown.
		for _, last := range h.last {
			last.DeviceID = ""
			last.State.pause(last.State.At)
		}
	}

	if opts.Report != nil {
		h.reports = startReports(opts.Report, log)
		ticker, done := time.NewTicker(reportAgainAfter/4), make(chan struct{})

		go func() {
			for {
				select {
				case <-ticker.C:
					h.reportAgain()
				case <-done:
					return
				}
			}
		}()
		h.stopReportingAgain = sync.OnceFunc(func() {
			ticker.Stop()
			close(done)
		})
	}

	return h
}

// Close closes every device's connection with CloseGoingAway, so that apps reconnect at once, to
// the hub that comes back, rather than find out on their next message, and waits up to closeWait
// for them to go offline. Then it writes what is still waiting to be written, and sends the reports
// still waiting. The hub must not be used afterwards. Calling Close again does nothing.
func (h *Hub) Close() {
	h.disconnectAll()

	if h.store != nil {
		h.store.close()
	}

	if h.reports != nil {
		h.stopReportingAgain()
		h.reports.close()
	}
}

// disconnectAll closes every device's connection and waits, up to closeWait, for them to end. A
// device going offline lets go of the last playback, its clock stopping now, as any other would.
func (h *Hub) disconnectAll() {
	h.mu.Lock()

	if h.closing {
		h.mu.Unlock()
		return
	}

	drained := make(chan struct{})
	h.closing, h.drained = true, drained

	for _, devices := range h.users {
		for _, e := range devices {
			if e.conn != nil {
				e.conn.Close(CloseGoingAway, "the hub is shutting down")
			}
		}
	}

	h.noteDrained()
	h.mu.Unlock()

	timer := time.NewTimer(closeWait)
	defer timer.Stop()

	select {
	case <-drained:
	case <-timer.C:
	}
}

// noteDrained lets Close go on once no device is online. Call with h.mu held.
func (h *Hub) noteDrained() {
	if h.drained == nil {
		return
	}

	for _, devices := range h.users {
		for _, e := range devices {
			if e.conn != nil {
				return
			}
		}
	}

	close(h.drained)
	h.drained = nil
}

// Session is one connection's life in the hub. The transport calls Message for each text frame,
// from a single goroutine, and Closed once at the end, from that same goroutine.
type Session struct {
	hub        *Hub
	conn       Conn
	entry      *entry // after a successful hello
	greeted    bool
	helloTimer *time.Timer
}

// Open starts the session of a new connection, which has Options.HelloTimeout to send its hello.
func (h *Hub) Open(conn Conn) *Session {
	return &Session{
		hub:        h,
		conn:       conn,
		helloTimer: time.AfterFunc(h.opts.HelloTimeout, func() { conn.Close(CloseBadHello, "no hello") }),
	}
}

// Message takes one text frame from the device: its hello, then any other message. ctx bounds the
// check of the hello's credentials with the media server.
func (s *Session) Message(ctx context.Context, raw []byte) {
	var msg incoming

	err := json.Unmarshal(raw, &msg)

	if !s.greeted {
		s.greeted = true
		s.helloTimer.Stop()

		if err != nil {
			s.conn.Close(CloseBadHello, "malformed hello")
			return
		}

		s.entry = s.hub.hello(ctx, s.conn, msg)
		return
	}

	switch {
	case s.entry == nil: // the hello failed and the connection is closing
	case err != nil:
		s.conn.Send(errorMsg{Type: "error", Error: codeBadMessage})
	default:
		s.hub.dispatch(s.entry, s.conn, msg)
	}
}

// Closed ends the session once the connection is gone. The device goes offline, unless a newer
// connection of it took over.
func (s *Session) Closed() {
	s.helloTimer.Stop()

	if s.entry != nil {
		s.hub.disconnect(s.entry, s.conn)
	}
}

// Sweep forgets offline devices not seen for longer than OfflineTTL.
func (h *Hub) Sweep() {
	h.mu.Lock()
	defer h.mu.Unlock()

	cutoff := h.opts.Now().Add(-h.opts.OfflineTTL)

	for user, devices := range h.users {
		for id, e := range devices {
			if e.conn != nil || !e.lastSeen.Before(cutoff) {
				continue
			}

			delete(devices, id)
			h.broadcast(e, func(*entry) any { return goneMsg{Type: "gone", DeviceID: id} })
		}

		if len(devices) == 0 {
			delete(h.users, user)
		}
	}
}

func (h *Hub) hello(ctx context.Context, conn Conn, msg incoming) *entry {
	if msg.Type != "hello" || msg.Protocol != ProtocolVersion {
		conn.Close(CloseBadHello, fmt.Sprintf("expected a hello for protocol %d", ProtocolVersion))
		return nil
	}

	auth, authOK := msg.Auth.clean()
	info := msg.Device
	if !authOK || !info.clean() {
		conn.Close(CloseBadHello, "malformed hello")
		return nil
	}

	user, ok, err := h.opts.Authenticate(ctx, auth)
	if err != nil {
		h.log.Warn("media server unreachable", "err", err)
		conn.Close(CloseUnavailable, "media server unreachable")
		return nil
	}

	if !ok || user == "" {
		h.log.Info("credentials rejected", "device", info.Name, "client", info.Client)
		conn.Close(CloseUnauthorized, "credentials rejected by the media server")
		return nil
	}

	h.mu.Lock()
	defer h.mu.Unlock()

	if h.closing {
		conn.Close(CloseGoingAway, "the hub is shutting down")
		return nil
	}

	devices := h.devicesOf(user)
	e := devices[info.ID]

	var replaced Conn

	if e == nil {
		e = &entry{user: strings.ToLower(user)}
		devices[info.ID] = e
	} else {
		replaced = e.conn
	}

	e.info, e.auth, e.conn, e.lastSeen = info, auth, conn, h.opts.Now()

	if replaced != nil {
		h.failPending(e, codeOffline)
		replaced.Close(CloseReplaced, "the device connected again")
	}

	others := []Device{}

	for _, other := range devices {
		if other != e {
			others = append(others, h.view(other, info.API))
		}
	}

	slices.SortFunc(others, func(a, b Device) int { return strings.Compare(a.ID, b.ID) })

	welcome := welcomeMsg{
		Type: "welcome", Protocol: ProtocolVersion, User: user,
		ServerTime: h.opts.Now().UnixMilli(), Devices: others,
	}

	if last := h.last[e.user]; last != nil {
		welcome.LastPlayback = &lastPlaybackMsg{
			DeviceID: last.DeviceID, DeviceName: last.DeviceName,
			State: h.translateState(last.State, last.API, info.API),
		}
	}

	conn.Send(welcome)
	h.announce(e)
	h.log.Info("device connected", "user", user, "device", info.Name, "client", info.Client)

	return e
}

func (h *Hub) disconnect(e *entry, conn Conn) {
	h.mu.Lock()
	defer h.mu.Unlock()

	if e.conn != conn {
		return // a newer connection of the same device took over
	}

	now := h.opts.Now()
	e.conn, e.lastSeen = nil, now
	h.failPending(e, codeOffline)

	if e.state != nil {
		// Offline, it doesn't play (SPEC.md, section 3). Left playing, it would come back announced
		// as playing, before its first report, and the other apps would follow it.
		e.state.pause(now.UnixMilli())
	}

	h.releaseLastPlayback(e)

	// Not as the hub shuts down: the device comes back in a moment, to the hub that restarts, and a
	// stop now would count a track twice where the media server counts it as it stops (Navidrome's
	// Jellyfin API, past half of it), besides a blip in its now playing.
	if !h.closing {
		h.notePlayback(e)
	}

	e.auth = Auth{}
	h.announce(e)
	h.noteDrained()
	h.log.Info("device disconnected", "user", e.user, "device", e.info.Name)
}

func (h *Hub) dispatch(e *entry, conn Conn, msg incoming) {
	h.mu.Lock()

	current := e.conn == conn

	h.mu.Unlock()

	if !current {
		return // late message on a connection that was replaced
	}

	switch msg.Type {
	case "state":
		h.onState(e, conn, msg)
	case "command":
		go h.onCommand(e, conn, msg) // waits for the player; the connection keeps reading meanwhile
	case "transfer":
		go h.onTransfer(e, conn, msg)
	case "result":
		h.onResult(e, msg)
	default:
		conn.Send(errorMsg{Type: "error", Error: codeBadMessage})
	}
}

func (h *Hub) onState(e *entry, conn Conn, msg incoming) {
	// Parsed before taking the lock, which a long queue would hold up for every user.
	report, ok := parseState(msg.State)

	h.mu.Lock()
	defer h.mu.Unlock()

	switch {
	case !e.info.isPlayer():
		conn.Send(errorMsg{Type: "error", Error: codeNotPlayer})
		return
	case !ok:
		conn.Send(errorMsg{Type: "error", Error: codeBadMessage})
		return
	}

	now := h.opts.Now()

	if e.state == nil {
		e.state = &StampedState{}
	}

	started := report.Status == Playing && e.state.Status != Playing

	e.state.merge(report)
	e.state.At, e.lastSeen = now.UnixMilli(), now
	h.noteLastPlayback(e)
	h.notePlayback(e)

	if started {
		h.stopOthers(e)
	}

	// Recipients merge the report into what they have, so relay only what the player sent.
	relayed := StampedState{PlayerState: report, At: now.UnixMilli()}

	h.broadcast(e, func(to *entry) any {
		return stateMsg{Type: "state", DeviceID: e.info.ID, State: h.translateState(relayed, e.info.API, to.info.API)}
	})
}

// stopOthers keeps one device playing at a time (SPEC.md, section 4): the user's other players
// that are playing are left (see leave), as by the device that started. Call with h.mu held; the
// commands go out once it is released.
func (h *Hub) stopOthers(e *entry) {
	for _, other := range h.users[e.user] {
		if other == e || other.conn == nil || other.state == nil || other.state.Status != Playing {
			continue
		}

		if command, ok := leave(other); ok {
			h.log.Info("one device at a time: stopping", "user", e.user, "device", other.info.Name, "for", e.info.Name)
			go h.request(other, command, other.info.API, e.info.ID)
		}
	}
}

// leave is what a player the music has left gets (SPEC.md, sections 4 and 6): a stop, so that it
// is idle rather than paused with a queue no one plays; a pause, if it plays but takes no stop. ok
// is false when there is nothing to send. Call with h.mu held.
func leave(e *entry) (command Command, ok bool) {
	switch {
	case e.info.obeys(ActStop):
		return Command{Action: ActStop}, true
	case e.state != nil && e.state.Status == Playing && e.info.obeys(ActPause):
		return Command{Action: ActPause}, true
	}

	return Command{}, false
}

func (h *Hub) onCommand(e *entry, conn Conn, msg incoming) {
	if msg.ID == "" {
		conn.Send(errorMsg{Type: "error", Error: codeBadMessage})
		return
	}

	command, ok := parseCommand(msg.Command)

	h.mu.Lock()

	target := h.users[e.user][msg.Target]
	fromAPI, from := e.info.API, e.info.ID

	h.mu.Unlock()

	var o outcome

	switch {
	case !ok:
		o.err = codeBadMessage
	case target == nil:
		o.err = codeUnknownDevice
	default:
		o = h.request(target, command, fromAPI, from)
	}

	conn.Send(resultMsg{Type: "result", Re: msg.ID, OK: o.ok, Error: o.err})
}

// onTransfer hands the source's queue, at its current position and in its modes, to the
// destination, then stops the source. Without a source, it is the user's last playback.
func (h *Hub) onTransfer(e *entry, conn Conn, msg incoming) {
	if msg.ID == "" {
		conn.Send(errorMsg{Type: "error", Error: codeBadMessage})
		return
	}

	reply := func(o outcome) { conn.Send(resultMsg{Type: "result", Re: msg.ID, OK: o.ok, Error: o.err}) }

	h.mu.Lock()

	devices := h.users[e.user]
	source, destination := devices[msg.From], devices[msg.To]
	from := e.info.ID
	play := msg.Play == nil || *msg.Play

	var state *StampedState // what moves: the source's, or the last playback's
	var sourceAPI API

	if source != nil {
		state, sourceAPI = source.state, source.info.API
	} else if last := h.last[e.user]; msg.From == "" && last != nil {
		// The device that holds it, as if from named it, or, when none does, the last playback
		// itself, its clock stopped, with no device to stop (SPEC.md, section 6).
		source = devices[last.DeviceID]
		state, sourceAPI = &last.State, last.API

		if source != nil {
			state = source.state
		}
	}

	var handoff Command
	var problem string

	switch {
	case destination == nil || (source == nil && msg.From != ""):
		problem = codeUnknownDevice
	case source == destination && msg.From != "":
		problem = codeBadMessage
	// An offline source still has its last state: the queue of a closed app can be picked up.
	case state == nil || len(state.Queue) == 0:
		problem = codeNothingToTransfer
	case source == destination:
		// Without a source, the destination holds the last playback: the music is already there.
		if play && state.Status != Playing {
			handoff = Command{Action: ActPlay}
		}
	default:
		index := 0

		if state.Index != nil {
			index = *state.Index
		}

		position := state.positionAt(h.opts.Now().UnixMilli())
		// With the modes it played in, shuffled in the same order, which shuffle going off takes back.
		handoff = Command{
			Action: ActSetQueue, Queue: state.Queue, Index: &index, PositionMs: &position, Play: &play,
			Repeat: state.Repeat, Shuffle: state.Shuffle, Order: state.Order,
		}
	}

	h.mu.Unlock()

	switch {
	case problem != "":
		reply(outcome{err: problem})
		return
	case handoff.Action == "":
		reply(outcome{ok: true})
		return
	}

	o := h.request(destination, handoff, sourceAPI, from)
	if o.ok && source != nil && source != destination {
		h.mu.Lock()

		var command Command
		var ok bool

		if source.conn != nil && source.state != nil && len(source.state.Queue) > 0 {
			command, ok = leave(source)
		}

		h.mu.Unlock()

		if ok {
			// Best effort: the music has already moved, so a source that won't stop doesn't undo it.
			h.request(source, command, sourceAPI, from)
		}
	}

	reply(o)
}

func (h *Hub) onResult(e *entry, msg incoming) {
	h.mu.Lock()
	defer h.mu.Unlock()

	p := h.pending[msg.Re]
	if p == nil || p.target != e {
		return // late, or not this device's to answer
	}

	o := outcome{ok: msg.OK}

	if !msg.OK {
		o.err = cmp.Or(msg.Error, codeFailed)
	}

	h.finish(msg.Re, o)
}

// request sends a command to a player and waits for its answer. fromAPI is the id space of the
// command's queue, if any.
func (h *Hub) request(target *entry, command Command, fromAPI API, from string) outcome {
	h.mu.Lock()

	switch {
	case target.conn == nil:
		h.mu.Unlock()
		return outcome{err: codeOffline}
	case !target.info.isPlayer():
		h.mu.Unlock()
		return outcome{err: codeNotPlayer}
	case !target.info.obeys(command.Action):
		h.mu.Unlock()
		return outcome{err: codeUnsupported}
	}

	if command.Action == ActSetQueue || command.Action == ActAddToQueue {
		command.Queue = h.translateQueue(command.Queue, fromAPI, target.info.API)
	}

	id := newID()
	p := &pending{target: target, done: make(chan outcome, 1)}
	h.pending[id] = p
	target.conn.Send(commandMsg{Type: "command", ID: id, From: from, Command: command})

	if probed, ok := target.conn.(prober); ok {
		probed.Probe()
	}

	h.mu.Unlock()

	timer := time.NewTimer(h.opts.CommandTimeout)
	defer timer.Stop()

	select {
	case o := <-p.done:
		return o
	case <-timer.C:
		h.mu.Lock()

		_, waiting := h.pending[id]

		delete(h.pending, id)
		h.mu.Unlock()

		if !waiting {
			return <-p.done // the answer arrived just as time ran out
		}

		return outcome{err: codeTimeout}
	}
}

// finish resolves a pending command. Call with h.mu held.
func (h *Hub) finish(id string, o outcome) {
	if p := h.pending[id]; p != nil {
		delete(h.pending, id)
		p.done <- o
	}
}

// failPending resolves every command waiting on a device. Call with h.mu held.
func (h *Hub) failPending(e *entry, err string) {
	for id, p := range h.pending {
		if p.target == e {
			h.finish(id, outcome{err: err})
		}
	}
}

// devicesOf returns (creating it if needed) a user's devices. Call with h.mu held.
func (h *Hub) devicesOf(user string) map[string]*entry {
	key := strings.ToLower(user)
	devices := h.users[key]
	if devices == nil {
		devices = map[string]*entry{}
		h.users[key] = devices
	}

	return devices
}

// announce tells the device's siblings about its info, presence and full state. Call with h.mu held.
func (h *Hub) announce(e *entry) {
	h.broadcast(e, func(to *entry) any { return deviceMsg{Type: "device", Device: h.view(e, to.info.API)} })
}

// broadcast sends to every other connected device of the same user, built for each recipient (whose
// API may differ). Call with h.mu held.
func (h *Hub) broadcast(source *entry, build func(to *entry) any) {
	for _, to := range h.users[source.user] {
		if to != source && to.conn != nil {
			to.conn.Send(build(to))
		}
	}
}

// view is a device as seen by a device that speaks api. Call with h.mu held.
func (h *Hub) view(e *entry, api API) Device {
	d := Device{DeviceInfo: e.info, Online: e.conn != nil}

	if e.state != nil {
		state := h.translateState(*e.state, e.info.API, api)
		d.State = &state
	}

	return d
}

func (h *Hub) translateState(state StampedState, from, to API) StampedState {
	if state.Queue != nil {
		state.Queue = h.translateQueue(state.Queue, from, to)
	}

	return state
}

func (h *Hub) translateQueue(queue []QueueItem, from, to API) []QueueItem {
	if from == to {
		return queue
	}

	out := make([]QueueItem, len(queue))

	for i, item := range queue {
		if item.ID != "" {
			item.ID, _ = h.opts.Translate(item.ID, from, to) // "" when it can't: metadata only
		}

		out[i] = item
	}

	return out
}

func newID() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)

	return hex.EncodeToString(b)
}
