# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Segue is a draft "Connect" protocol (like Spotify Connect) for OpenSubsonic/Jellyfin music apps,
plus its reference hub:

- `SPEC.md`: the protocol. Where it and the protocol code disagree, one of them has a bug, so a
  protocol change touches `SPEC.md`, the hub (`hub/`) and the app's Dart side together. Code
  comments cite it by section ("SPEC.md, section 4").
- `hub/`: the reference hub in Go (package `hub`, usable as a library; binary in `cmd/segue-hub`).

The first real client, a Spotify-like Flutter player for Navidrome and Jellyfin, is in another
repository, `github.com/mateusguilherme/segue-app`, usually cloned next to this one as
`../segue-app`. Its side of the protocol is in its `lib/segue/`, so a protocol change is a commit
in each repository. It lived here in `app/` until 2026-10-05, and took its history along.

A TypeScript reference client used to live in `client/`; `git checkout c22dc7b -- client` restores it.

## Commands (Go 1.27)

```sh
cd hub
go test -race ./...
go test -race -run TestTransfer ./...        # one test
go build -o segue-hub ./cmd/segue-hub
SEGUE_UPSTREAM=http://127.0.0.1:4533 ./segue-hub
```

Without Go installed, the same through Docker (from `hub/`):

```sh
docker run --rm -u "$(id -u):$(id -g)" -v "$PWD":/src -w /src -e HOME=/tmp golang:1.27 go test -race ./...
docker run --rm -u "$(id -u):$(id -g)" -v "$PWD":/src -w /src -e HOME=/tmp -e CGO_ENABLED=0 golang:1.27 go build -o segue-hub ./cmd/segue-hub
```

Configuration is all environment variables (`SEGUE_UPSTREAM`, `SEGUE_LISTEN`, `SEGUE_STATE`,
`SEGUE_AUTH`); see the table in `README.md`. The hub asks `SEGUE_UPSTREAM` what it is at startup
(`DetectUpstream`), and waits for it to answer. `SEGUE_AUTH=none` accepts any device as the user it
claims, for tests and demos only.

The app's tests against the hub (segue-app's `test/hub_test.dart`) run the binary built here, at
`hub/segue-hub`, with `SEGUE_AUTH=none`, and find its port by parsing the log line
`msg="hub listening" url=http://...` from `cmd/segue-hub/main.go`. Changing that line breaks them.

## Hub architecture

- The core (`hub.go`) does not depend on the transport: a transport calls `Hub.Open(conn)` per
  connection, then `Session.Message` for each text frame and `Session.Closed` at the end, all from
  one goroutine. `server.go` is the gorilla/websocket transport. Its `wsConn` queues outgoing frames
  for a writer goroutine, because `Conn.Send`/`Close` are called with the hub's lock held and must
  never block.
- All hub state sits behind a single `h.mu`. Helpers marked "Call with h.mu held" assume it.
  Commands to players (`request`) wait for the answer outside the lock, matched by id through
  `pending`.
- `Options` holds the pluggable parts: `Authenticator` (`UpstreamAuthenticator` asks the media
  server who the credentials belong to and caches successes; `DevAuthenticator` for
  `SEGUE_AUTH=none`), `IDTranslator` (`NavidromeIDs` converts between Subsonic base62 ids and
  Jellyfin GUIDs, mirroring Navidrome's own code), and an injectable clock (`Now`) used by the tests.
- `DetectUpstream` (`auth.go`) tells the kind of media server from a Subsonic ping without
  credentials (OpenSubsonic's `type` says Navidrome) or Jellyfin's `System/Info/Public`.
  `ErrNotAMediaServer` is a wrong URL; other errors are a server not answering yet.
- Messages are built per recipient (`broadcast`, `view`), because each device receives queue ids in
  its own API (`subsonic` or `jellyfin`).
- `last.go` holds each user's "last playback" (SPEC section 7). It is the only state that can reach
  disk (`SEGUE_STATE`), written by a background store.
- `report.go` tells the media server what each device plays (SPEC section 12), with the device's
  credentials, which the hub holds only while it is connected. `notePlayback` decides when (another
  track, play, pause or stop, a seek), and `reportQueue` sends from a goroutine of its own, so the
  hub never waits on the media server; it merges a device's reports of a track but keeps stops and
  starts, so that a track ends before the next starts and Jellyfin counts each start.
  `reportAgain` repeats an unchanged report every minute, since Jellyfin drops a playback it hears
  nothing of. `UpstreamReporter` picks the API by the device's credentials: `SubsonicReporter` uses
  `reportPlayback` (OpenSubsonic `playbackReport`), or `scrobble`'s now playing where the server
  lacks it; `JellyfinReporter` uses Jellyfin's sessions, signed as the device, and counts a play
  (`Sessions/Playing`) only for a track that starts from its start.
- `Handler` serves `/v1/info` and `/v1/ws` both at the root and under `/connect/`, whether or not
  the reverse proxy strips the prefix.
- Hub tests (`hub_test.go`) drive real WebSocket connections against `httptest` servers.

## Conventions

- Code, comments, `README.md` and `SPEC.md` are in English. Error codes from the hub reach users
  through the app, which turns them into Portuguese messages (`describeError` in segue-app's
  `lib/ui/errors.dart`), so a new error string needs an entry there.
- Commit messages are in Portuguese: a short title (prefixed `Hub:` for hub-only changes) and a
  body explaining the behaviour and why.
- `README.md` has "Next steps". Update it when a feature lands.
- Docs, comments and tests stay generic: no names from a particular setup (machine or device names,
  hostnames, server paths, the tooling of the server it is developed on). Use names like `laptop`,
  `phone`, `tv` and `music.example`.
