package hub

import (
	"encoding/json"
	"errors"
	"io/fs"
	"log/slog"
	"os"
	"path/filepath"
	"sync"
)

// lastPlayback is a user's most recent playback (SPEC.md, "Last playback"): what the device that
// played last had, kept across disconnects and, with a store, across restarts.
type lastPlayback struct {
	DeviceID   string       `json:"deviceId"` // empty once that device went offline, until one takes it over
	DeviceName string       `json:"deviceName"`
	API        API          `json:"api"` // the id space of State.Queue
	State      StampedState `json:"state"`
}

// noteLastPlayback updates the user's last playback after e reported. A device takes it over only
// by playing, or as the destination of a transfer (takeLastPlayback): loading it, as an app that
// opens does, doesn't. The device that has it also updates it while paused. A report without a
// queue (an app that just opened, empty) never touches it. Call with h.mu held.
func (h *Hub) noteLastPlayback(e *entry) {
	state := e.state
	if state == nil || len(state.Queue) == 0 {
		return
	}

	last := h.last[e.user]
	if state.Status != Playing && (last == nil || last.DeviceID != e.info.ID) {
		return
	}

	h.last[e.user] = &lastPlayback{DeviceID: e.info.ID, DeviceName: e.info.Name, API: e.info.API, State: *state}
	h.saveLast()
}

// takeLastPlayback gives the user's last playback to e, the device a transfer has just moved the
// music to with handoff, a setQueue whose queue has api's ids (SPEC.md, sections 6 and 7). It does
// so whether the music plays there or not: moved paused, it would otherwise stay with the source,
// which the transfer leaves idle. Until e reports, it is the music as handed over. Call with h.mu
// held.
func (h *Hub) takeLastPlayback(e *entry, handoff Command, api API) {
	status := Paused

	if *handoff.Play {
		status = Playing
	}

	state := PlayerState{
		Status: status, PositionMs: *handoff.PositionMs, Queue: handoff.Queue, Index: handoff.Index,
		Repeat: handoff.Repeat, Shuffle: handoff.Shuffle, Order: handoff.Order,
	}

	h.last[e.user] = &lastPlayback{
		DeviceID: e.info.ID, DeviceName: e.info.Name, API: api,
		State: StampedState{PlayerState: state, At: h.opts.Now().UnixMilli()},
	}
	h.saveLast()
}

// releaseLastPlayback lets go of the last playback when the device that holds it goes offline
// (SPEC.md, section 7): its clock stops where playback had got to, and no device holds it until one
// plays or a transfer moves it. An app that opens then shows it on its own, not on that device,
// even once it is back. Call with h.mu held.
func (h *Hub) releaseLastPlayback(e *entry) {
	last := h.last[e.user]
	if last == nil || last.DeviceID != e.info.ID {
		return
	}

	last.State.pause(h.opts.Now().UnixMilli())
	last.DeviceID = ""
	h.saveLast()
}

// saveLast hands the last playbacks to the store, if there is one. Call with h.mu held.
//
// It hands a copy, which the store encodes outside the lock, as encoding every user's queue would
// hold up the hub on each report. The copy shares the queues and the fields behind pointers, which
// a report replaces and never changes in place.
func (h *Hub) saveLast() {
	if h.store == nil {
		return
	}

	last := make(map[string]lastPlayback, len(h.last))

	for user, l := range h.last {
		last[user] = *l
	}

	h.store.save(last)
}

// store writes the last playbacks to a JSON file in the background, so the hub never waits on the
// disk. Only the newest version waiting is written.
type store struct {
	path    string
	log     *slog.Logger
	mu      sync.Mutex
	pending map[string]lastPlayback // nil: nothing to write
	wake    chan struct{}
	done    chan struct{}
	stopped chan struct{}
	once    sync.Once
}

// openStore reads the file, if it exists, and starts the writer.
func openStore(path string, log *slog.Logger) (*store, map[string]*lastPlayback) {
	last := map[string]*lastPlayback{}
	data, err := os.ReadFile(path)

	switch {
	case errors.Is(err, fs.ErrNotExist):
	case err != nil:
		log.Error("can't read the last playbacks", "path", path, "err", err)
	default:
		if err := json.Unmarshal(data, &last); err != nil {
			log.Error("the last playbacks file is broken; starting without it", "path", path, "err", err)
			last = map[string]*lastPlayback{}
		}
	}

	s := &store{
		path: path, log: log,
		wake: make(chan struct{}, 1), done: make(chan struct{}), stopped: make(chan struct{}),
	}

	go s.run()

	return s, last
}

func (s *store) save(last map[string]lastPlayback) {
	s.mu.Lock()
	s.pending = last
	s.mu.Unlock()

	select {
	case s.wake <- struct{}{}:
	default: // a write is already due, and it will take this version
	}
}

func (s *store) run() {
	defer close(s.stopped)

	for {
		select {
		case <-s.wake:
			s.flush()
		case <-s.done:
			s.flush()
			return
		}
	}
}

func (s *store) flush() {
	s.mu.Lock()

	last := s.pending
	s.pending = nil
	s.mu.Unlock()

	if last == nil {
		return
	}

	data, err := json.Marshal(last)
	if err != nil {
		s.log.Error("can't encode the last playbacks", "err", err)
		return
	}

	// Written whole to a temporary file and renamed, so a crash never leaves half a file.
	tmp := filepath.Join(filepath.Dir(s.path), "."+filepath.Base(s.path)+".tmp")

	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		s.log.Error("can't write the last playbacks", "path", tmp, "err", err)
		return
	}

	if err := os.Rename(tmp, s.path); err != nil {
		s.log.Error("can't write the last playbacks", "path", s.path, "err", err)
	}
}

func (s *store) close() {
	s.once.Do(func() { close(s.done) })
	<-s.stopped
}
