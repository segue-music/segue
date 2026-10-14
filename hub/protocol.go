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

// The APIs a device can speak.
const (
	Subsonic API = "subsonic"
	Jellyfin API = "jellyfin"
)

// Role is what a device does: a player plays and obeys commands, a controller sends them. A device
// can be both.
type Role string

// The roles a device can take.
const (
	RolePlayer     Role = "player"
	RoleController Role = "controller"
)

// Status is a player's playback status. A stopped player is idle, whether or not it has a queue.
type Status string

// The statuses a player reports.
const (
	Playing Status = "playing"
	Paused  Status = "paused"
	Stopped Status = "stopped"
)

// Repeat is a player's repeat mode: off, the whole queue (after the last track, the first), or the
// current track.
type Repeat string

// The repeat modes.
const (
	RepeatOff Repeat = "off"
	RepeatAll Repeat = "all"
	RepeatOne Repeat = "one"
)

func (r Repeat) valid() bool { return r == RepeatOff || r == RepeatAll || r == RepeatOne }

// Action is what a command asks of a player (SPEC.md, section 5). A player lists the ones it obeys
// in DeviceInfo.Capabilities.
type Action string

// The actions of commands.
const (
	ActPlay            Action = "play"
	ActPause           Action = "pause"
	ActToggle          Action = "toggle"
	ActStop            Action = "stop"
	ActNext            Action = "next"
	ActPrevious        Action = "previous"
	ActJump            Action = "jump"
	ActSeek            Action = "seek"
	ActSetVolume       Action = "setVolume"
	ActSetQueue        Action = "setQueue"
	ActSetRepeat       Action = "setRepeat"
	ActSetShuffle      Action = "setShuffle"
	ActAddToQueue      Action = "addToQueue"
	ActMoveInQueue     Action = "moveInQueue"
	ActRemoveFromQueue Action = "removeFromQueue"
)

var knownActions = map[Action]bool{
	ActPlay: true, ActPause: true, ActToggle: true, ActStop: true, ActNext: true, ActPrevious: true, ActJump: true,
	ActSeek: true, ActSetVolume: true, ActSetQueue: true, ActSetRepeat: true, ActSetShuffle: true, ActAddToQueue: true,
	ActMoveInQueue: true, ActRemoveFromQueue: true,
}

// Close codes (SPEC.md, section 2).
const (
	CloseUnauthorized = 4001 // the media server rejected the credentials
	CloseBadHello     = 4002 // no valid hello, or an unsupported protocol version
	CloseReplaced     = 4003 // the same device connected again
	CloseUnavailable  = 1011 // the media server didn't answer
)

// Error codes the hub reports itself, in error and result messages (SPEC.md, section 5). Any other
// error in a result is the player's own text.
const (
	codeBadMessage        = "badMessage"
	codeUnknownDevice     = "unknownDevice"
	codeOffline           = "offline"
	codeNotPlayer         = "notPlayer"
	codeUnsupported       = "unsupported" // the action isn't in the player's capabilities
	codeTimeout           = "timeout"
	codeNothingToTransfer = "nothingToTransfer"
	codeFailed            = "failed" // a player's result not ok, without an error of its own
)

// Auth is what the device already uses with the media server. The hub checks it there.
type Auth struct {
	Scheme   Scheme `json:"scheme"`
	Username string `json:"username,omitempty"`
	Token    string `json:"token,omitempty"`
	Salt     string `json:"salt,omitempty"`
	APIKey   string `json:"apiKey,omitempty"`
}

// Scheme is the kind of credentials in an Auth, which says the fields it has (SPEC.md, section 2).
type Scheme string

// The schemes of Auth.
const (
	SchemeSubsonic Scheme = "subsonic" // Username, Token and Salt, as in a Subsonic API call
	SchemeAPIKey   Scheme = "apiKey"   // APIKey, from OpenSubsonic's apiKeyAuthentication
	SchemeJellyfin Scheme = "jellyfin" // Token, a Jellyfin access token
)

// clean keeps only the fields of the scheme, and reports whether they are all there.
func (a Auth) clean() (Auth, bool) {
	switch a.Scheme {
	case SchemeSubsonic:
		return Auth{Scheme: a.Scheme, Username: a.Username, Token: a.Token, Salt: a.Salt},
			a.Username != "" && a.Token != "" && a.Salt != ""
	case SchemeAPIKey:
		return Auth{Scheme: a.Scheme, APIKey: a.APIKey}, a.APIKey != ""
	case SchemeJellyfin:
		return Auth{Scheme: a.Scheme, Token: a.Token}, a.Token != ""
	}

	return Auth{}, false
}

// DeviceInfo is how a device describes itself in its hello (SPEC.md, section 2).
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
	// ReportsPlayback says the app tells the media server what it plays by itself, so the hub
	// doesn't do it for it (SPEC.md, section 12).
	ReportsPlayback bool `json:"reportsPlayback,omitempty"`
}

// clean checks the fields and drops repeated roles and capabilities. Capabilities this hub doesn't
// know are dropped too: a newer app still connects, without the commands this hub can't route.
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
		if knownActions[a] && !slices.Contains(capabilities, a) {
			capabilities = append(capabilities, a)
		}
	}

	d.Roles, d.Capabilities = roles, capabilities

	return true
}

func (d *DeviceInfo) isPlayer() bool           { return slices.Contains(d.Roles, RolePlayer) }
func (d *DeviceInfo) obeys(action Action) bool { return slices.Contains(d.Capabilities, action) }

// QueueItem is a track in a player's queue, with enough metadata to be shown without asking the
// media server (SPEC.md, section 4).
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
	Repeat     Repeat      `json:"repeat,omitempty"` // "": unchanged
	Shuffle    *bool       `json:"shuffle,omitempty"`
	// Order is, for a shuffled queue, each item's place in the queue unshuffled, which shuffle going
	// off goes back to (SPEC.md, section 4). It comes and goes with Queue: nil with one, none.
	Order []int `json:"order,omitzero"`
}

func (s *PlayerState) merge(report PlayerState) {
	s.Status, s.PositionMs = report.Status, report.PositionMs

	if report.Queue != nil {
		s.Queue, s.Order = report.Queue, report.Order
	}

	if report.Index != nil {
		s.Index = report.Index
	}

	if report.Volume != nil {
		s.Volume = report.Volume
	}

	if report.Repeat != "" {
		s.Repeat = report.Repeat
	}

	if report.Shuffle != nil {
		s.Shuffle = report.Shuffle
	}
}

// StampedState is a state as the hub relays it: At is the hub time (epoch ms) at which PositionMs held.
type StampedState struct {
	PlayerState
	At int64 `json:"at"`
}

// pause stops the clock of a playing state at hub time now (epoch ms), where playback had got to.
func (s *StampedState) pause(now int64) {
	if s.Status != Playing {
		return
	}

	s.PositionMs = s.positionAt(now)
	s.Status, s.At = Paused, now
}

// positionAt is where playback is at hub time now (epoch ms), extrapolated from the last report.
func (s *StampedState) positionAt(now int64) int64 {
	if s.Status != Playing {
		return s.PositionMs
	}

	position := s.PositionMs + max(0, now-s.At)

	if item, ok := s.current(); ok && item.DurationMs > 0 {
		position = min(position, item.DurationMs)
	}

	return position
}

// current is the queue's item at index, if there is one.
func (s *PlayerState) current() (QueueItem, bool) {
	index := 0

	if s.Index != nil {
		index = *s.Index
	}

	if index < len(s.Queue) {
		return s.Queue[index], true
	}

	return QueueItem{}, false
}

// Command is what a controller asks of a player. The hub passes on only the fields of its Action
// (SPEC.md, section 5).
type Command struct {
	Action     Action      `json:"action"`
	PositionMs *int64      `json:"positionMs,omitempty"`
	Volume     *int        `json:"volume,omitempty"`
	Queue      []QueueItem `json:"queue,omitzero"`
	Index      *int        `json:"index,omitempty"`
	Play       *bool       `json:"play,omitempty"`
	Repeat     Repeat      `json:"repeat,omitempty"`
	Shuffle    *bool       `json:"shuffle,omitempty"`
	// Order is, for the shuffled queue of a setQueue, each item's place in the queue unshuffled.
	Order []int `json:"order,omitzero"`
	// Next puts the tracks of an addToQueue right after the current one, rather than at the end.
	Next *bool `json:"next,omitempty"`
	// To is where a moveInQueue takes the track at Index: the place it then has in the queue.
	To *int `json:"to,omitempty"`
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
		(state.Volume == nil || (*state.Volume >= 0 && *state.Volume <= 100)) &&
		(state.Repeat == "" || state.Repeat.valid()) && validOrder(state.Order, state.Queue)

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
	case ActJump:
		return Command{Action: c.Action, Index: c.Index}, c.Index != nil && *c.Index >= 0
	case ActSeek:
		return Command{Action: c.Action, PositionMs: c.PositionMs}, c.PositionMs != nil && *c.PositionMs >= 0
	case ActSetVolume:
		return Command{Action: c.Action, Volume: c.Volume}, c.Volume != nil && *c.Volume >= 0 && *c.Volume <= 100
	case ActSetRepeat:
		return Command{Action: c.Action, Repeat: c.Repeat}, c.Repeat.valid()
	case ActSetShuffle:
		return Command{Action: c.Action, Shuffle: c.Shuffle}, c.Shuffle != nil
	case ActSetQueue:
		// The modes are optional; an order goes only with a shuffled queue.
		ok := c.Queue != nil && validQueue(c.Queue) && c.Index != nil && *c.Index >= 0 &&
			c.PositionMs != nil && *c.PositionMs >= 0 && c.Play != nil && (c.Repeat == "" || c.Repeat.valid()) &&
			validOrder(c.Order, c.Queue) && (c.Order == nil || (c.Shuffle != nil && *c.Shuffle))
		return Command{
			Action: c.Action, Queue: c.Queue, Index: c.Index, PositionMs: c.PositionMs, Play: c.Play,
			Repeat: c.Repeat, Shuffle: c.Shuffle, Order: c.Order,
		}, ok
	case ActAddToQueue:
		ok := len(c.Queue) > 0 && validQueue(c.Queue) && c.Next != nil
		return Command{Action: c.Action, Queue: c.Queue, Next: c.Next}, ok
	case ActMoveInQueue:
		ok := c.Index != nil && *c.Index >= 0 && c.To != nil && *c.To >= 0
		return Command{Action: c.Action, Index: c.Index, To: c.To}, ok
	case ActRemoveFromQueue:
		return Command{Action: c.Action, Index: c.Index}, c.Index != nil && *c.Index >= 0
	}

	return Command{}, false
}

// validOrder says whether order is none, or each place in queue once: a queue's order unshuffled.
func validOrder(order []int, queue []QueueItem) bool {
	if order == nil {
		return true
	}

	if queue == nil || len(order) != len(queue) {
		return false
	}

	seen := make([]bool, len(order))

	for _, place := range order {
		if place < 0 || place >= len(order) || seen[place] {
			return false
		}

		seen[place] = true
	}

	return true
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
	Type         string           `json:"type"`
	Protocol     int              `json:"protocol"`
	User         string           `json:"user"`
	ServerTime   int64            `json:"serverTime"`
	Devices      []Device         `json:"devices"`
	LastPlayback *lastPlaybackMsg `json:"lastPlayback,omitempty"`
}

// lastPlaybackMsg is a last playback as a device receives it: the queue already in its API.
type lastPlaybackMsg struct {
	DeviceID   string       `json:"deviceId"`
	DeviceName string       `json:"deviceName"`
	State      StampedState `json:"state"`
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
