// Package hub is the reference hub of the Segue protocol (SPEC.md). It signs devices in with the
// media server, keeps each user's devices and the last state of each player, relays that state and
// routes commands between devices.
package hub

import (
	"encoding/json"
	"slices"
)

// ProtocolVersion is the protocol version this hub speaks.
const ProtocolVersion = 1

// API is the media server API a device speaks. Item ids in its messages belong to that API.
type API string

const (
	Subsonic API = "subsonic"
	Jellyfin API = "jellyfin"
)

type Role string

const (
	RolePlayer     Role = "player"
	RoleController Role = "controller"
)

type Status string

const (
	Playing Status = "playing"
	Paused  Status = "paused"
	Stopped Status = "stopped"
)

type Action string

const (
	ActPlay      Action = "play"
	ActPause     Action = "pause"
	ActToggle    Action = "toggle"
	ActStop      Action = "stop"
	ActNext      Action = "next"
	ActPrevious  Action = "previous"
	ActSeek      Action = "seek"
	ActSetVolume Action = "setVolume"
	ActSetQueue  Action = "setQueue"
)

var knownActions = map[Action]bool{
	ActPlay: true, ActPause: true, ActToggle: true, ActStop: true, ActNext: true, ActPrevious: true,
	ActSeek: true, ActSetVolume: true, ActSetQueue: true,
}

// Close codes (SPEC.md, section 2).
const (
	CloseUnauthorized = 4001 // the media server rejected the credentials
	CloseBadHello     = 4002 // no valid hello, or an unsupported protocol version
	CloseReplaced     = 4003 // the same device connected again
	CloseUnavailable  = 1011 // the media server didn't answer
)

// Auth is what the device already uses with the media server. The hub checks it there.
type Auth struct {
	Scheme   string `json:"scheme"`
	Username string `json:"username,omitempty"`
	Token    string `json:"token,omitempty"`
	Salt     string `json:"salt,omitempty"`
	APIKey   string `json:"apiKey,omitempty"`
}

// clean keeps only the fields of the scheme, and reports whether they are all there.
func (a Auth) clean() (Auth, bool) {
	switch a.Scheme {
	case "subsonic":
		return Auth{Scheme: a.Scheme, Username: a.Username, Token: a.Token, Salt: a.Salt},
			a.Username != "" && a.Token != "" && a.Salt != ""
	case "apiKey":
		return Auth{Scheme: a.Scheme, APIKey: a.APIKey}, a.APIKey != ""
	case "jellyfin":
		return Auth{Scheme: a.Scheme, Token: a.Token}, a.Token != ""
	}
	return Auth{}, false
}

type DeviceInfo struct {
	// ID is stable per installation (a UUID the app keeps), not per connection.
	ID      string `json:"id"`
	Name    string `json:"name"`
	Client  string `json:"client"`
	Version string `json:"version,omitempty"`
	API     API    `json:"api"`
	Roles   []Role `json:"roles"`
	// Capabilities are the commands the device obeys as a player.
	Capabilities []Action `json:"capabilities"`
}

// clean checks the fields and drops repeated roles and capabilities.
func (d *DeviceInfo) clean() bool {
	if d.ID == "" || d.Name == "" || d.Client == "" || (d.API != Subsonic && d.API != Jellyfin) {
		return false
	}
	roles := []Role{}
	for _, r := range d.Roles {
		if r != RolePlayer && r != RoleController {
			return false
		}
		if !slices.Contains(roles, r) {
			roles = append(roles, r)
		}
	}
	capabilities := []Action{}
	for _, a := range d.Capabilities {
		if !knownActions[a] {
			return false
		}
		if !slices.Contains(capabilities, a) {
			capabilities = append(capabilities, a)
		}
	}
	d.Roles, d.Capabilities = roles, capabilities
	return true
}

func (d *DeviceInfo) isPlayer() bool           { return slices.Contains(d.Roles, RolePlayer) }
func (d *DeviceInfo) obeys(action Action) bool { return slices.Contains(d.Capabilities, action) }

type QueueItem struct {
	// ID is the media server's id, in the recipient's API. Empty when the hub couldn't translate it.
	ID         string `json:"id,omitempty"`
	Title      string `json:"title,omitempty"`
	Artist     string `json:"artist,omitempty"`
	Album      string `json:"album,omitempty"`
	DurationMs int64  `json:"durationMs,omitempty"`
}

// PlayerState is what a player reports. Status and PositionMs go in every report; an optional field
// left out (nil) keeps its previous value.
type PlayerState struct {
	Status     Status      `json:"status"`
	PositionMs int64       `json:"positionMs"`
	Queue      []QueueItem `json:"queue,omitzero"` // nil: unchanged; empty: no queue
	Index      *int        `json:"index,omitempty"`
	Volume     *int        `json:"volume,omitempty"`
}

func (s *PlayerState) merge(report PlayerState) {
	s.Status, s.PositionMs = report.Status, report.PositionMs
	if report.Queue != nil {
		s.Queue = report.Queue
	}
	if report.Index != nil {
		s.Index = report.Index
	}
	if report.Volume != nil {
		s.Volume = report.Volume
	}
}

// StampedState is a state as the hub relays it: At is the hub time (epoch ms) at which PositionMs held.
type StampedState struct {
	PlayerState
	At int64 `json:"at"`
}

// positionAt is where playback is at hub time now (epoch ms), extrapolated from the last report.
func (s *StampedState) positionAt(now int64) int64 {
	if s.Status != Playing {
		return s.PositionMs
	}
	position := s.PositionMs + max(0, now-s.At)
	index := 0
	if s.Index != nil {
		index = *s.Index
	}
	if index < len(s.Queue) && s.Queue[index].DurationMs > 0 {
		position = min(position, s.Queue[index].DurationMs)
	}
	return position
}

type Command struct {
	Action     Action      `json:"action"`
	PositionMs *int64      `json:"positionMs,omitempty"`
	Volume     *int        `json:"volume,omitempty"`
	Queue      []QueueItem `json:"queue,omitzero"`
	Index      *int        `json:"index,omitempty"`
	Play       *bool       `json:"play,omitempty"`
}

// Device is a device as other devices see it.
type Device struct {
	DeviceInfo
	Online bool          `json:"online"`
	State  *StampedState `json:"state,omitempty"`
}

// incoming holds any message a device sends; Type says which fields matter.
type incoming struct {
	Type     string          `json:"type"`
	Protocol int             `json:"protocol"`
	Auth     Auth            `json:"auth"`
	Device   DeviceInfo      `json:"device"`
	State    json.RawMessage `json:"state"`
	ID       string          `json:"id"`
	Target   string          `json:"target"`
	Command  json.RawMessage `json:"command"`
	From     string          `json:"from"`
	To       string          `json:"to"`
	Play     *bool           `json:"play"`
	Re       string          `json:"re"`
	OK       bool            `json:"ok"`
	Error    string          `json:"error"`
}

func parseState(raw json.RawMessage) (PlayerState, bool) {
	var s struct {
		PlayerState
		PositionMs *int64 `json:"positionMs"` // a pointer, to tell a missing position from 0
	}
	if json.Unmarshal(raw, &s) != nil || s.PositionMs == nil || *s.PositionMs < 0 {
		return PlayerState{}, false
	}
	state := s.PlayerState
	state.PositionMs = *s.PositionMs
	ok := (state.Status == Playing || state.Status == Paused || state.Status == Stopped) &&
		validQueue(state.Queue) && (state.Index == nil || *state.Index >= 0) &&
		(state.Volume == nil || (*state.Volume >= 0 && *state.Volume <= 100))
	return state, ok
}

// parseCommand returns a command with only the fields of its action.
func parseCommand(raw json.RawMessage) (Command, bool) {
	var c Command
	if json.Unmarshal(raw, &c) != nil {
		return Command{}, false
	}
	switch c.Action {
	case ActPlay, ActPause, ActToggle, ActStop, ActNext, ActPrevious:
		return Command{Action: c.Action}, true
	case ActSeek:
		return Command{Action: c.Action, PositionMs: c.PositionMs}, c.PositionMs != nil && *c.PositionMs >= 0
	case ActSetVolume:
		return Command{Action: c.Action, Volume: c.Volume}, c.Volume != nil && *c.Volume >= 0 && *c.Volume <= 100
	case ActSetQueue:
		ok := c.Queue != nil && validQueue(c.Queue) && c.Index != nil && *c.Index >= 0 &&
			c.PositionMs != nil && *c.PositionMs >= 0 && c.Play != nil
		return Command{Action: c.Action, Queue: c.Queue, Index: c.Index, PositionMs: c.PositionMs, Play: c.Play}, ok
	}
	return Command{}, false
}

func validQueue(queue []QueueItem) bool {
	for _, item := range queue {
		if item.DurationMs < 0 {
			return false
		}
	}
	return true
}

// Messages from the hub.

type welcomeMsg struct {
	Type       string   `json:"type"`
	Protocol   int      `json:"protocol"`
	User       string   `json:"user"`
	ServerTime int64    `json:"serverTime"`
	Devices    []Device `json:"devices"`
}

type deviceMsg struct {
	Type   string `json:"type"`
	Device Device `json:"device"`
}

type stateMsg struct {
	Type     string       `json:"type"`
	DeviceID string       `json:"deviceId"`
	State    StampedState `json:"state"`
}

type goneMsg struct {
	Type     string `json:"type"`
	DeviceID string `json:"deviceId"`
}

type commandMsg struct {
	Type    string  `json:"type"`
	ID      string  `json:"id"`
	From    string  `json:"from"`
	Command Command `json:"command"`
}

type resultMsg struct {
	Type  string `json:"type"`
	Re    string `json:"re"`
	OK    bool   `json:"ok"`
	Error string `json:"error,omitempty"`
}

type errorMsg struct {
	Type  string `json:"type"`
	Error string `json:"error"`
}
