# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Segue is a draft "Connect" protocol for OpenSubsonic/Jellyfin music apps, plus its reference hub:

- `SPEC.md`: the protocol. Where it and the protocol code disagree, one of them has a bug, so a
  protocol change touches `SPEC.md`, the hub (`hub/`) and the app's Dart side together. Code
  comments cite it by section ("SPEC.md, section 4").
- `hub/`: the reference hub in Go (package `hub`, usable as a library; binary in `cmd/segue-hub`).

The first real client, a Flutter music player for Navidrome and Jellyfin, is in another
repository, `github.com/segue-music/segue-app`, usually cloned next to this one as
`../segue-app`. Its side of the protocol is in its `lib/segue/`, so a protocol change is a commit
in each repository. It lived here in `app/` until 2026-10-05, and took its history along.

A TypeScript reference client used to live in `client/`; `git checkout 3a9604b -- client` restores it.

## Commands (Go 1.27)

```sh
cd hub
go vet ./... && gofmt -l .                   # gofmt lists the files it would change
go test -race ./...
go test -race -run TestTransfer ./...        # one test
go build -o segue-hub ./cmd/segue-hub
SEGUE_UPSTREAM=http://127.0.0.1:4533 ./segue-hub
```

Without Go installed, the same through Docker (from `hub/`):

```sh
docker run --rm -u "$(id -u):$(id -g)" -v "$PWD":/src -w /src -e HOME=/tmp golang:1.27 sh -c 'go vet ./... && gofmt -l .'
docker run --rm -u "$(id -u):$(id -g)" -v "$PWD":/src -w /src -e HOME=/tmp golang:1.27 go test -race ./...
docker run --rm -u "$(id -u):$(id -g)" -v "$PWD":/src -w /src -e HOME=/tmp -e CGO_ENABLED=0 golang:1.27 go build -o segue-hub ./cmd/segue-hub
```

The image (`hub/Dockerfile`) is `scratch` with the binary, cross-compiled for each platform, and a
`/data` folder that its user, 65532, owns, where `SEGUE_STATE` points.
`.github/workflows/hub-image.yml` publishes it as `ghcr.io/segue-music/segue-hub` (amd64, arm64,
armv7) on each push to `main` that changes `hub/`, after `go vet`, `gofmt` and the tests.

Configuration is all environment variables (`SEGUE_UPSTREAM`, `SEGUE_LISTEN`, `SEGUE_STATE`,
`SEGUE_AUTH`); see the table in `README.md`. The hub asks `SEGUE_UPSTREAM` what it is at startup
(`DetectUpstream`), and waits for it to answer. `SEGUE_AUTH=none` accepts any device as the user it
claims, for tests and demos only, and lets `SEGUE_UPSTREAM` be empty (the hub then assumes Navidrome).

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
  the reverse proxy strips the prefix. Pages in a browser reach both from any origin, unless
  `Options.AllowOrigin` says otherwise: with `SEGUE_AUTH=none`, `cmd/segue-hub` allows only pages
  served from the same machine.
- Hub tests (`hub_test.go`) drive real WebSocket connections against `httptest` servers.

## Conventions

- Code, comments, `README.md` and `SPEC.md` are in English. Error codes from the hub (the `code`
  constants in `protocol.go`) reach users through the app, which turns them into messages in their
  language (`describeError` in segue-app's `lib/ui/widgets/errors.dart`, from its ARB files), so a
  new one needs an entry there.
- Commit messages are in Portuguese: a short title (prefixed `Hub:` for hub-only changes) and a
  body explaining the behaviour and why.
- `README.md` has "Next steps". Update it when a feature lands.
- The hub follows the app's code conventions (segue-app's `CLAUDE.md`), in their Go form below.
- Go layout is `gofmt`'s, except for blank lines, which it keeps but never adds, so these are by
  hand. A statement with braces (`if`, `for`, `switch`, `select`, a bare block, a local function or
  struct type over several lines) has a blank line before and after it, separating it from the
  statements around it, but not at the start or end of its block. The `return` that ends a
  function (a method, a closure) has one above it too, where other statements come before it. A
  run of `:=` declarations is a group of its own, and so is a run of `var` declarations: a blank
  line separates either from the other and from a statement that calls something (a function, a
  method, a `defer` or a `go`: `h.mu.Lock()`, `go s.run()`), before or after it. A comment above a
  statement or a group belongs to it, so the blank line goes above the comment. Two Go idioms stay
  right under the statement that assigned what they use: the `if` that checks it
  (`res, err := client.Do(req)` then `if err != nil {`; `var urlErr *url.Error` then
  `if errors.As(err, &urlErr) {`) and the `defer` that releases it (`defer ping.Stop()`).
- A local variable is declared where it is first needed, below the `return`s (or `continue`s,
  `break`s, `panic`s) that leave without it, so that leaving there computes nothing it won't use.
  It stays above them where the order matters: what has to be read under `h.mu`, before the lock
  is released (`from := e.info.ID` in `onTransfer`), work kept out of the lock (`parseState` in
  `onState`), a value kept before the code between changes it, or one whose computing has to
  happen either way. A statement declaring several values at once (`report, ok := ...`) stays
  whole.
- Go design follows Effective Go (https://go.dev/doc/effective_go) and the Go Code Review Comments
  (https://go.dev/wiki/CodeReviewComments). `gofmt` and `go vet` check what they can; the rest is by
  hand: terms used consistently, a doc comment on every exported name that starts with it,
  initialisms in one case (`ID`, `API`, `URL`), no `Get` prefix, short names for short scopes
  (`e`, `p`, `err`) and fuller ones for wider, errors that start in lower case, end without a
  period and say where they come from (`hub:`, the endpoint).
- A comment says what the code can't: why it is so, what it works around, what a number means.
  One that only says again what the code says goes. Where every member of a list of fields or of a
  const block has its doc, the obvious one stays, rather than leave a gap, and so does an exported
  name's doc comment, which Effective Go asks of every one.
- What fails, with the hub going on without it, says so in the log: through the hub's
  `*slog.Logger` (`Options.Logger`), as
  `q.log.Warn("can't report to the media server", "device", p.Device, "err", err)`, never
  `fmt.Print` or the `log` package, which miss the logger the program gave the hub. What can't
  fail, or fails with its connection already gone, is dropped with `_` (`_ = ws.Close()`).
- No name ends in `_`, and none hides a package or a function that the code around it calls: when
  the obvious one is taken (`url`, `jellyfinBase`), pick a fuller one (`hubURL`, `jellyfinBaseURL`).
- Docs, comments and tests stay generic: no names from a particular setup (machine or device names,
  hostnames, server paths, the tooling of the server it is developed on). Use names like `laptop`,
  `phone`, `tv` and `music.example`.
