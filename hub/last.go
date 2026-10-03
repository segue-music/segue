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
	DeviceID   string       `json:"deviceId"`
	DeviceName string       `json:"deviceName"`
	API        API          `json:"api"` // the id space of State.Queue
	State      StampedState `json:"state"`
}

// noteLastPlayback updates the user's last playback after e reported. A device takes it over by
// playing; the device that has it also updates it while paused. A report without a queue (an app
// that just opened, empty) never touches it. Call with h.mu held.
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

// freezeLastPlayback stops the clock of a last playback whose device went away while playing, at
// the position it had reached. Call with h.mu held.
func (h *Hub) freezeLastPlayback(e *entry) {
	last := h.last[e.user]
	if last == nil || last.DeviceID != e.info.ID || last.State.Status != Playing {
		return
	}
	now := h.opts.Now().UnixMilli()
	last.State.PositionMs = last.State.positionAt(now)
	last.State.Status, last.State.At = Paused, now
	h.saveLast()
}

// saveLast hands the last playbacks to the store, if there is one. Call with h.mu held.
func (h *Hub) saveLast() {
	if h.store == nil {
		return
	}
	data, err := json.Marshal(h.last)
	if err != nil {
		h.log.Error("can't encode the last playbacks", "err", err)
		return
	}
	h.store.save(data)
}

// Close writes what is still waiting to be written. The hub must not be used afterwards.
func (h *Hub) Close() {
	if h.store != nil {
		h.store.close()
	}
}

// store writes the last playbacks to a JSON file in the background, so the hub never waits on the
// disk. Only the newest version waiting is written.
type store struct {
	path    string
	log     *slog.Logger
	mu      sync.Mutex
	pending []byte
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

func (s *store) save(data []byte) {
	s.mu.Lock()
	s.pending = data
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
	data := s.pending
	s.pending = nil
	s.mu.Unlock()
	if data == nil {
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
