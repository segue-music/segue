# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Segue is a draft "Connect" protocol (like Spotify Connect) for OpenSubsonic/Jellyfin music apps,
plus its reference implementations:

- `SPEC.md`: the protocol. Where it and the protocol code disagree, one of them has a bug, so a
  protocol change touches `SPEC.md`, the hub (`hub/`) and the app's Dart side (`app/lib/segue/`)
  together. Code comments cite it by section ("SPEC.md, section 4").
- `hub/`: the reference hub in Go (package `hub`, usable as a library; binary in `cmd/segue-hub`).
- `app/`: a Spotify-like Flutter player for Navidrome, the first real client.

A TypeScript reference client used to live in `client/`; `git checkout c22dc7b -- client` restores it.

## Commands

### Hub (Go 1.27)

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

Configuration is all environment variables (`SEGUE_UPSTREAM`, `SEGUE_UPSTREAM_KIND`,
`SEGUE_LISTEN`, `SEGUE_STATE`, `SEGUE_AUTH`); see the table in `README.md`. `SEGUE_AUTH=none`
accepts any device as the user it claims, for tests and demos only.

### App (Flutter 3.47)

Flutter runs from a Docker image through `app/tool/flutter.sh` (as the current user, repo mounted),
so nothing needs installing. Build the image once:

```sh
cd app
docker build -t segue-flutter-dev -f tool/dev.Dockerfile tool
tool/flutter.sh pub get
tool/flutter.sh analyze
DART=1 tool/flutter.sh format lib test        # page width 120 (analysis_options.yaml)
tool/flutter.sh test
tool/flutter.sh test test/player_test.dart    # one file
tool/flutter.sh test --plain-name 'a refused hello is a final HubClosed'
tool/package-linux.sh                         # release build → build/segue-linux-x64.tar.gz
DART=1 tool/flutter.sh run tool/icons.dart    # every icon (Android, TV banner, Linux) from tool/icon.png
```

The Android build (phones and Android TV) uses a second image, with the JDK and Android SDK/NDK:

```sh
docker build -t segue-flutter-android -f tool/android.Dockerfile tool
tool/package-android.sh                       # → build/segue-android.apk (debug-signed, every ABI)
```

With Flutter installed locally, the same commands work as `flutter ...` (`flutter run -d linux`).

Test prerequisites:
- `test/hub_test.dart` runs the app's client and `ConnectController` against the real Go hub binary
  at `../hub/segue-hub` (or `SEGUE_HUB_BIN`), so build the hub first. It starts the hub with
  `SEGUE_AUTH=none` and finds its port by parsing the log line `msg="hub listening" url=http://...`
  from `cmd/segue-hub/main.go`. Changing that line breaks these tests.
- `test/media_kit_engine_test.dart` uses the real libmpv with audio output disabled. The dev image
  has libmpv; elsewhere these tests are skipped.

Running two app instances on one machine as different devices:
`env SEGUE_DEVICE_ID=second SEGUE_DEVICE_NAME="Second copy" segue/segue`.

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
- Messages are built per recipient (`broadcast`, `view`), because each device receives queue ids in
  its own API (`subsonic` or `jellyfin`).
- `last.go` holds each user's "last playback" (SPEC section 7). It is the only state that can reach
  disk (`SEGUE_STATE`), written by a background store.
- `Handler` serves `/v1/info` and `/v1/ws` both at the root and under `/connect/`, whether or not
  the reverse proxy strips the prefix.
- Hub tests (`hub_test.go`) drive real WebSocket connections against `httptest` servers.

## App architecture

- `services.dart`: `Services.start` wires one signed-in session: `SubsonicApi` →
  `PlayerController` → `ConnectController`, plus a `SegueClient` if a hub was discovered (otherwise
  the app only plays locally). `ServicesScope` hands this down the tree. It sits in
  `MaterialApp.builder` (`app.dart`), above the navigator, so pages, sheets and the keyboard
  shortcuts all see it.
- `PlayerController` (`lib/player/`) is this device's player over an `AudioEngine` interface.
  `MediaKitEngine` (libmpv) is the real engine; `test/fakes.dart` has `FakeEngine` for tests.
  `MediaKitEngine` works around media_kit in a few places, each pinned by
  `media_kit_engine_test.dart` against the real libmpv. It tracks the current index itself, since
  media_kit's `state.playlist.index` briefly drops to 0 on every open. It keeps the position it
  commanded (seek, jump, open) until media_kit's catches up, so the report right after isn't stale.
  It reapplies shuffle after each open, since media_kit turns it off. And it reports when a track
  starts over on repeat. The play order (`order`) maps the shuffled playlist back to the songs.
- `ConnectController` (`lib/connect/`) follows Spotify's model: the app controls one device at a
  time (`activeId`, null meaning this device). UI actions go through it (`playSongs`, `toggle`,
  `seek`, ...): it either runs them on the local player or sends them as hub commands. The UI should
  call `connect`, not `player`, for playback. It also follows whichever device starts playing, and
  restores the last playback on first connect. It links the player and the hub:
  `player.onReport → client.sendState` and `client.onCommand → player.obey`.
- `lib/segue/`: protocol types, the client (reconnects with backoff; stops on final close codes
  4001/4002/4003) and hub discovery (`/connect/v1/info` next to the server).
- `MediaControls` (`lib/player/media_controls.dart`) mirrors `connect.nowPlaying` to the system's
  media controls. Linux (MPRIS) only for now.
- `Session` keeps the Subsonic token and salt in secure storage and everything else in
  `shared_preferences`. The password itself is never stored.
- Android TV: the remote drives the app through focus. `segueTheme` (`lib/ui/theme.dart`) gives
  focused buttons a ring and everything else a strong tint, and `FocusRing` draws a ring on tiles
  whose image hides the tint. `FocusRing` must keep the same widget tree with or without focus,
  since rebuilding the child would drop its focus as soon as it arrived. On a TV
  (`lib/television.dart`, asking `MainActivity.kt`), focus highlights are always on: Flutter starts
  Android in touch mode and ignores key events from virtual keyboards, which is what
  `adb shell input keyevent` sends. `TextFieldArrowShortcuts` lets up and down leave text fields.
- `MainActivity` extends audio_service's `AudioServiceActivity`, so the screen and the plugin share
  one Flutter engine. With a plain `FlutterActivity`, audio_service started an engine of its own,
  and with it a second, hidden copy of the app that connected to the hub as the same device. It
  also answers `lib/device.dart` (TV or not, the device's name in the system settings).

## Conventions

- The app's UI text is in Portuguese. Code, comments, `README.md` files and `SPEC.md` are in English.
  Error codes from the hub and players become Portuguese messages in `describeError`
  (`lib/ui/errors.dart`), so a new error string needs an entry there.
- Commit messages are in Portuguese: a short title (prefixed `App:` for app-only changes) and a
  body explaining the behaviour and why.
- `app/README.md` lists what the app does and what it doesn't do yet, and the root `README.md` has
  "Next steps". Update both when a feature lands.
- Docs, comments and tests stay generic: no names from a particular setup (machine or device names,
  hostnames, server paths, the tooling of the server it is developed on). Use names like `laptop`,
  `phone`, `tv` and `music.example`.
