# Segue protocol, version 1 (draft)

Status: **draft 0**, 2026-10-03. Not proposed anywhere yet. This repository has a reference hub
(`hub/`, Go), and the first client is an app in Flutter
([segue-app](https://github.com/segue-music/segue-app)). Where this text and their protocol
code disagree, that is a bug in one of them.

## The problem

Spotify Connect lets every device see what plays on the others, control any of them, and move the
music from one to another. Self-hosted music has nothing like it across apps:

- The **Subsonic/OpenSubsonic API** is request and response: the server never speaks first, so it
  can't tell an app to do anything. `jukeboxControl` drives a single output on the server and few
  apps implement it. `getNowPlaying` shows tracks but no position or control. `savePlayQueue` keeps
  a queue on the server, but it doesn't move playback or stop the other device.
- **Jellyfin** has sessions with remote control over its WebSocket, but only between Jellyfin apps,
  only for apps that implement the receiving side, and not in servers that offer a Jellyfin-compatible
  API (Navidrome's has no sessions).
- **Music Assistant** gets there by being the player itself: its own app and queue. Subsonic apps
  stay outside.

No server-side component can make an app obey a command: the app has to be listening. What is
missing is a **small shared protocol** that an app implements once and that works with any server.
The OpenSubsonic discussion about a "Jam" function
([#277](https://github.com/opensubsonic/open-subsonic-api/discussions/277)) points at the same gap.

## Goals

- One protocol for apps of both ecosystems.
- No accounts of its own: a device signs in with the credentials it already uses with the media
  server.
- Works next to a server that knows nothing about it (a companion "hub"), and can later be built
  into a server.
- Items are the media server's ids, and audio still comes from the media server: the hub never
  streams.
- Small enough to add to an app in a few hundred lines.

Not goals, for now: synchronized playback on several devices (multi-room, Jam), queues edited by
several people, waking an app that isn't running, and playing on devices that run no compatible app.
The last one can be done with bridges ([section 11](#11-bridges)).

## Overview

```
 phone app ──┐                      ┌── checks credentials ──► media server
 TV app    ──┼── WebSocket ── hub ──┘                          (Navidrome, Jellyfin, ...)
 desktop   ──┘                                                       ▲
     └────────────── audio, straight from the media server ──────────┘
```

- A **device** is one installation of an app. It is a **player** (plays audio and obeys commands),
  a **controller** (shows the other devices and commands them), or both.
- The **hub** keeps, for each user, their devices and the last state of each player. It relays
  state and routes commands, and tells the media server what plays
  ([section 12](#12-the-media-servers-now-playing)). Only each user's last playback may go to disk
  ([section 7](#7-last-playback)).

## 1. Discovery

A client knows its media server's base URL, `B` (say `https://music.example.org`, or
`https://music.example.org/jellyfin`). It looks for the hub at:

1. `B/connect/v1/info`;
2. if `B` has a path, at `/connect/v1/info` on the origin of `B`.

A `200` with `{"protocol": "segue", "versions": [1], ...}` means a hub is there, with its
WebSocket at `.../connect/v1/ws`. The server's admin publishes the hub by routing `/connect/` on
the media server's origin to it. Clients should also accept a hub URL typed by the user, and probe
once per sign-in, not on every request.

A server that implements the hub itself could advertise it instead, for instance as an OpenSubsonic
extension in `getOpenSubsonicExtensions` ([open questions](#13-open-questions)).

## 2. Connection and authentication

A WebSocket carrying JSON text frames, one message per frame. Every message has a `type`. Times,
positions and durations are integer milliseconds, and volume is an integer from 0 to 100. The
device's first message is `hello`:

```json
{
  "type": "hello",
  "protocol": 1,
  "auth": { "scheme": "subsonic", "username": "alice", "token": "26719a1196d2a940705a59634eb18eab", "salt": "c19b2d" },
  "device": {
    "id": "5b0c8d4e-1f0a-4e57-9a43-2f6f1b2a7c11",
    "name": "Alice's iPhone",
    "client": "Amperfy",
    "version": "1.9.0",
    "api": "subsonic",
    "roles": ["player", "controller"],
    "capabilities": ["play", "pause", "toggle", "stop", "next", "previous", "seek", "setVolume", "setQueue"]
  }
}
```

`auth` is what the app already sends to the media server. The hub asks the media server who it
belongs to:

| `scheme` | Fields | The hub checks with |
|---|---|---|
| `subsonic` | `username`, `token`, `salt` | `GET /rest/ping` |
| `apiKey` | `apiKey` | `GET /rest/tokenInfo` (OpenSubsonic `apiKeyAuthentication`) |
| `jellyfin` | `token` | `GET /Users/Me` |

Subsonic's plain-password form (`p=`) is not accepted.

`device`:

- `id`: stable for the installation, such as a UUID the app keeps. The same id connecting again
  replaces the old connection.
- `name`: what users see.
- `client`, `version`: the app.
- `api`: `subsonic` or `jellyfin`, the API the app uses. Ids in its messages belong to that API.
- `roles`: `player`, `controller`, or both.
- `capabilities`: the commands it obeys as a player ([section 5](#5-commands)). The hub ignores
  the ones it doesn't know, and so should apps, so that a newer app still works with an older hub.
- `reportsPlayback` (optional): `true` when the app tells the media server what it plays by itself
  (`scrobble`, `reportPlayback`), so that the hub doesn't do it for it
  ([section 12](#12-the-media-servers-now-playing)).

The hub answers with `welcome`:

```json
{ "type": "welcome", "protocol": 1, "user": "alice", "serverTime": 1790000000000, "devices": [] }
```

`devices` lists the user's other devices, online and recently offline, with the last state of each
([section 3](#3-devices)). `serverTime` is the hub's clock, in epoch milliseconds
([section 4](#4-player-state-and-the-clock)).

The hub groups devices by user name, ignoring case. On Navidrome both APIs have the same user names,
so a Jellyfin app and a Subsonic app of the same person see each other.

If the hub closes the connection, the code tells why:

| Code | Meaning | What the client does |
|---|---|---|
| 4001 | The media server rejected the credentials | Stop until the credentials change |
| 4002 | No valid `hello` (or none within 10 s), or an unsupported `protocol` | Fix the client |
| 4003 | The same device connected again elsewhere | Don't reconnect on its own |
| 1011 | The media server didn't answer | Reconnect with backoff |

## 3. Devices

A `Device` is the device's `hello` info plus `online` and, for players that reported, `state`. The
hub sends each device news of the user's other devices:

- `{"type": "device", "device": Device}` when one connects, disconnects or changes its info.
  Replace what you had.
- `{"type": "state", "deviceId": "...", "state": {...}}` when a player reports. Merge it into what
  you had ([section 4](#4-player-state-and-the-clock)).
- `{"type": "gone", "deviceId": "..."}` when an offline device expires (after 24 hours in the
  reference hub).

An offline device stays listed with its last state, so its queue can still be picked up
([section 6](#6-transfer)). Its clock stops as it goes offline: a device that was playing is listed
`paused`, at the position it had reached, and comes back online that way until it reports. Otherwise
the other apps would take it, back before its first report, for a device that just started playing.

## 4. Player state and the clock

A player reports on every change (track, play or pause, seek, queue, volume). It doesn't need to
report periodically:

```json
{
  "type": "state",
  "state": {
    "status": "playing",
    "positionMs": 42000,
    "index": 0,
    "volume": 80,
    "repeat": "off",
    "shuffle": false,
    "queue": [
      { "id": "5QFKvMsJrd57QE2Le2dKKo", "title": "Dream On", "artist": "Aerosmith", "album": "Aerosmith", "durationMs": 268000 }
    ]
  }
}
```

- `status` (`playing`, `paused`, `stopped`) and `positionMs` go in every report. Together they
  define the clock.
- The other fields are optional, and one left out keeps its previous value. A player with a long
  queue can leave `queue` out when it hasn't changed.
- `queue` is the play order as the player has it (after shuffling). Each item has its id, in the
  player's API, and enough metadata to be shown without a lookup.
- `index` is the current track's position in `queue`. `volume` goes from 0 to 100.
- `repeat` is `off`, `all` (after the last track, the first) or `one` (the current track, again and
  again). `shuffle` says whether the queue was shuffled: when it is, `queue` is already in the
  shuffled order. A player that repeats a track reports when it starts over.

The hub adds `at`, its own time when the report arrived, and relays the report to the other
devices. Any device computes where playback is now as `positionMs + (hubNow - at)` while `playing`,
where `hubNow` is the local time plus the offset measured at `welcome` (`serverTime` minus the local
time). Nobody depends on device clocks being right.

**One device plays at a time**, as with Spotify: when a player's report goes from not playing to
`playing`, the hub sends `stop` to the user's other players that are playing (`pause` to one that
takes no `stop`), as a command from the device that started. The music has moved, and they are left
idle, not paused with it. Reports from a device that already plays (a new track, say) don't do it
again. Every app then sees, and follows, the one device that plays.

## 5. Commands

A controller sends:

```json
{ "type": "command", "id": "r1", "target": "<deviceId>", "command": { "action": "seek", "positionMs": 90000 } }
```

The hub passes it to the player with its own id, as
`{"type": "command", "id": "<hub id>", "from": "<controller id>", "command": {...}}`. The player
obeys and answers `{"type": "result", "re": "<hub id>", "ok": true}` (or `"ok": false` with an
`error`), then reports its new state. The hub answers the controller with
`{"type": "result", "re": "r1", "ok": true}`.

| `action` | Fields | Effect |
|---|---|---|
| `play`, `pause`, `toggle`, `stop` | | |
| `next` | | The next track; after the last one, the first, unless `repeat` is `off` |
| `previous` | | Back to the start of the track; in its first 3 seconds, to the previous track. On the first track, always back to its start |
| `jump` | `index` | The track at `index` in `queue`, from its start, playing. On the current track, it starts over |
| `seek` | `positionMs` | |
| `setVolume` | `volume` (0–100) | |
| `setQueue` | `queue`, `index`, `positionMs`, `play` | Replace the queue and go to `index` at `positionMs`, playing if `play` |
| `setRepeat` | `repeat` (`off`, `all`, `one`) | |
| `setShuffle` | `shuffle` (true or false) | On, shuffle the queue, the current track still playing; off, back to the order it had. Either way, report the new `queue` |

Errors the hub reports itself: `unknownDevice`; `offline`; `notPlayer`; `unsupported` (the action
isn't in the player's `capabilities`, so it wasn't sent); `timeout` (no answer in 10 s);
`badMessage`. Any other `error` is the player's own text.

## 6. Transfer

```json
{ "type": "transfer", "id": "r2", "from": "<source>", "to": "<destination>", "play": true }
```

The hub:

1. takes the source's last state and works out its position now;
2. sends the destination a `setQueue` with that queue, index and position (ids translated,
   [section 8](#8-ids-across-apis));
3. if that worked and the source is online, sends it a `stop` (a `pause`, if it plays and takes no
   `stop`), so that it is left idle, not paused with music that now plays elsewhere (best effort:
   the music has already moved);
4. answers the request with the destination's result, or `nothingToTransfer` when the source has
   no queue.

The source may be offline: its last state is enough. The destination may be the device asking,
which is "continue here".

## 7. Last playback

The hub keeps, for each user, the **last playback**: the state of the device that played last, so
that an app opened after every app was closed can show where the music was, Spotify-style. It is
the hub's own record, separate from the devices' states:

- a device takes it over only by reporting `playing` with a queue; the device that holds it also
  updates it while paused (a seek, say);
- a report without a queue never touches it: an app that has just opened, empty, does not wipe it;
- when the device that holds it goes offline, it lets go of it: its clock stops (the position
  becomes where playback had got to, and the status `paused`), and no device holds it until one
  plays. Coming back online doesn't give it back;
- the reference hub can keep it on disk, so that it survives a restart. A restart disconnects every
  device, so after one no device holds it.

`welcome` carries it, with the queue in the device's API, when there is one. `deviceId` is the
device that holds it, empty when none does; `deviceName` says where it was played:

```json
{ "type": "welcome", "...": "...",
  "lastPlayback": { "deviceId": "...", "deviceName": "Living room TV", "state": { "status": "paused", "positionMs": 40000, "at": 1790000000000, "index": 1, "queue": [] } } }
```

An app that opens with nothing playing anywhere shows it: on the device that holds it, if one does
(it is then online, and the app controls it); otherwise here, loaded paused at the same point, so
that play continues it here. Loading it doesn't take it over: until some device plays, every app
that opens shows it the same way, on its own.

## 8. Ids across APIs

Queue items always reach a device with ids in that device's API. The hub translates when it knows
how:

- **Navidrome** serves the same library through both APIs, and the ids are the same 128-bit number:
  22 characters of base62 in Subsonic, a 32-hex GUID in Jellyfin (Navidrome's `model/id` and
  `server/jellyfin/dto/ids.go`).
- When the hub can't translate an id, it leaves `id` out of the item. The metadata is still there,
  so the device can look the item up by title, artist and album, or skip it.

## 9. Liveness and mobile apps

- The hub pings each connection every 30 s (WebSocket ping) and drops one that hasn't answered by
  the next ping.
- Clients reconnect with backoff, then send `hello` and a state report again.
- On iOS and Android, an app playing in the background keeps running and keeps its connection. A
  paused app in the background gets suspended: it stays listed as offline with its last state, so
  its queue can still be picked up, but it takes no commands until it opens again. Apps should
  report their state on pausing, before they are suspended. Waking an app with a push notification
  is out of scope for version 1.

## 10. Security

- The hub checks every connection with the media server, and keeps a few minutes' cache of
  successful checks, keyed by a hash. It holds a device's credentials only in memory, while the
  device is connected, to report its playback ([section 12](#12-the-media-servers-now-playing)),
  and never writes them to disk.
- A device sees and commands only devices of the same user.
- Commands reach only players, and only for the actions they declared.
- `hello` carries credentials, so the hub must be reached over TLS (`wss://`) and run by the media
  server's admin, as the media server would be.

## 11. Bridges

The hub only routes messages, so other programs can register devices of their own:

- a Chromecast, UPnP or AirPlay bridge that registers each speaker as a player;
- an observer that lists apps not speaking the protocol, by polling the server's now-playing data
  (`getNowPlaying`, Jellyfin's `/Sessions`), as devices with no capabilities, leaving out what the
  hub reported itself ([section 12](#12-the-media-servers-now-playing));
- a media server that implements the hub itself.

## 12. The media server's now playing

The media server has a "now playing" of its own (`getNowPlaying`, Navidrome's activity panel,
Jellyfin's sessions), which apps fill by reporting what they play. The hub fills it for its devices,
so that music playing through Segue shows there under the name of the device that plays it:

- It reports, with the device's own credentials, each change the media server shows: another track,
  play, pause or stop, a seek. A new volume or queue isn't one. Another track first stops the one
  before, where it got to. A device that goes offline is reported stopped, since the hub can no
  longer tell what it plays. A device that plays, or is paused, is reported again, unchanged, after
  a minute without a report, since Jellyfin stops a playback it hears nothing of.
- It reports in the API of the device's credentials, in which the device's ids are: the Subsonic API
  for `subsonic` and `apiKey`, Jellyfin's (under `/jellyfin` on Navidrome) for `jellyfin`. A device
  whose `api` isn't that of its credentials isn't reported.
- In the Subsonic API, `c`, the client's name, is the device's `name`, which the media server shows
  as the player. Where the server has OpenSubsonic's `playbackReport` extension (Navidrome 0.62 and
  later), the hub calls `reportPlayback` with `ignoreScrobble`: what plays shows, and no play is
  counted. Elsewhere it calls `scrobble` with `submission=false`, which knows no pause or stop: a
  paused track stays listed until it would have ended.
- In Jellyfin's API, the hub signs each report as the device signs its own requests: its token,
  with the device's `id` as `DeviceId`, `client` as `Client`, `name` as `Device` and `version`.
  The media server then takes it for the device's own, and shows the name and app the device signed
  in with. So a Jellyfin app that speaks Segue uses its Segue device `id` as its Jellyfin
  `DeviceId`. A track starts with `Sessions/Playing`, goes on with `Sessions/Playing/Progress` and
  ends with `Sessions/Playing/Stopped`, which always carries where it stopped.
- It doesn't report for a device whose `hello` says, with `reportsPlayback`, that it reports by
  itself, as most Jellyfin apps do.

Plays are counted as each API counts them. In the Subsonic API the hub counts none
(`ignoreScrobble`). Jellyfin counts one on each `Sessions/Playing`, so the hub sends it only for a
track that starts playing from its start, and `Sessions/Playing/Progress` for one that it hears of
later (moved from another device, or the device back online), which shows it without counting.
Navidrome's Jellyfin API counts a play when a track stops past half of it or four minutes
([open questions](#13-open-questions)).

## 13. Open questions

- User identity across APIs on servers other than Navidrome (Jellyfin with a Subsonic plugin, for
  instance), where user names may not match.
- Editing the queue (play next, add to queue) without replacing it.
- Repeat and shuffle on a transfer: `setQueue` carries the queue in its play order, but neither
  mode, so the destination keeps its own.
- Group playback ("Jam"): one queue, several devices listening. It would need a way out of "one
  device plays at a time" (section 4) for the devices in the group.
- Advertising the hub: an OpenSubsonic extension and a Jellyfin plugin, instead of the `/connect`
  probe.
- Waking mobile apps with push notifications.
- Partial queue updates for very long queues.
- Counting plays from the hub in the Subsonic API. The server counts a track when a report says it
  stopped past half of it, so a track moved by a transfer, which stops on one device and ends on
  another, would count twice. Navidrome's Jellyfin API counts the same way, so there a transfer past
  half of a track counts it twice already.

## Related work

- Spotify Connect: the model, closed.
- Jellyfin sessions, remote control and SyncPlay.
- Subsonic `jukeboxControl`, and the OpenSubsonic Playback Report extension.
- Music Assistant, and its Sendspin protocol for players.
- MPRIS and UPnP AVTransport, which the command set mirrors.
