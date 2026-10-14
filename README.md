<p align="center"><img src="icon.png" alt="" width="160"></p>

<h1 align="center">Segue</h1>

<h3 align="center">Connect for self-hosted music.</h3>

<p align="center">
  Each of your devices sees what the others are playing, controls any of them, and moves the music
  from one to another without losing its place, across apps and servers. A draft of an open
  protocol for apps on OpenSubsonic (Navidrome and others) or Jellyfin, a reference hub that runs
  next to the media server, and a music player built on them.
</p>

<p align="center">
  <a href="SPEC.md">Protocol</a> ·
  <a href="IMPLEMENTING.md">Implementing it</a> ·
  <a href="#hub">Hub</a> ·
  <a href="https://github.com/segue-music/segue-app">App</a> ·
  <a href="#next-steps">Next steps</a>
</p>

> [!NOTE]
> **Vibe-coded.** The spec, the hub and the app were written by Claude (through Claude Code), with
> a person deciding what to build and trying it on real devices. Every commit says so.

---

Apps can't be commanded by anything on the server side unless they listen for it, so Segue is a
protocol that apps implement once, plus a small hub that runs next to the media server. The hub
signs devices in with the credentials they already use with the media server, keeps the state of
each player, and routes commands. Audio still comes from the media server. The problem, the design
and the messages are in [SPEC.md](SPEC.md).

**Status: skeleton.** The protocol is a first draft. The hub works in its tests and with the
first client, an app of its own ([segue-app](https://github.com/segue-music/segue-app)); both
have run next to a real Navidrome since 2026-10-03. The app isn't released: its Android APK, in no
store, its Linux tarball and its Windows zip are only in its repository's releases, and its iOS
build reaches only TestFlight's internal group.

## Layout

| Folder | What |
|---|---|
| `SPEC.md` | The protocol |
| `IMPLEMENTING.md` | The app's side of it, in the order an app developer builds it |
| `hub/` | The reference hub, in Go. Package `hub` (usable as a library), binary in `cmd/segue-hub` |

The hub is in Go, the language of Navidrome, so that it can move into a media server. It also
uses the same WebSocket library as Navidrome (`gorilla/websocket`). As a separate service it is
one static binary: an 11 MB image, using about 2 MB of RAM when idle.

The app, a music player for Navidrome, other OpenSubsonic servers and Jellyfin in Flutter
(Linux, Windows, macOS, Android, iOS), is in its own repository,
[segue-music/segue-app](https://github.com/segue-music/segue-app), with its side of the
protocol in Dart (`lib/segue/`). It lived here, in `app/`, until 2026-10-05. A client in another
language follows `SPEC.md`, and [IMPLEMENTING.md](IMPLEMENTING.md) walks through it. A reference
client in TypeScript, for apps like Feishin and Jellify, lived in `client/` until 2026-10-03:
`git checkout 3a9604b -- client` brings it back.

## Hub

Needs Go 1.27.

```sh
cd hub
go test -race ./...
go build -o segue-hub ./cmd/segue-hub
SEGUE_UPSTREAM=http://127.0.0.1:4533 ./segue-hub
```

| Variable | Default | |
|---|---|---|
| `SEGUE_UPSTREAM` | (required, except with `SEGUE_AUTH=none`) | The media server's URL, as the hub reaches it. The hub asks it at startup, until it answers, whether it is Navidrome (Subsonic API, Jellyfin API at `/jellyfin`, ids translated), another Subsonic server or Jellyfin |
| `SEGUE_LISTEN` | `127.0.0.1:8480` | Address and port |
| `SEGUE_STATE` | | A file where each user's last playback is kept across restarts (SPEC, section 7). Empty keeps it in memory only |
| `SEGUE_AUTH` | | `none` accepts any device, as the Subsonic user it claims (`dev` for other schemes). Only for trying things out, and then without a media server if `SEGUE_UPSTREAM` is empty |

The hub also tells the media server what each device plays, with the device's own credentials
(SPEC, section 12), so Navidrome's Now Playing and Jellyfin's sessions show Segue's devices by name.
In the Subsonic API it uses OpenSubsonic's `reportPlayback` (Navidrome 0.62 and later) where the
server has it, and counts no plays. In Jellyfin's it uses the sessions API, and Jellyfin counts a
play for each track that starts from its start. With `SEGUE_AUTH=none` it reports nothing.

Clients find the hub at `/connect/` on the media server's origin, so route that path there in the
reverse proxy. It must be `https`, because devices send their credentials.

With Docker: `docker build -t segue-hub hub/`, then run it with the variables above. The image
listens on `0.0.0.0:8480`.

## Next steps

1. The app: trying the iOS build on an iPhone and in a car (see
   [segue-app](https://github.com/segue-music/segue-app)).
2. An observer that lists apps that don't speak the protocol (from `getNowPlaying`, leaving out what
   the hub reports itself), as devices that can be seen but not commanded. That covers apps like
   Symfonium, which is closed source.
3. Try the app on a real Jellyfin server and on Navidrome's Jellyfin API: that Navidrome's two APIs
   give the same user names, and that the ids translate on real items.
4. Propose it to the open-source apps. It went to Navidrome as design input
   ([#5154](https://github.com/navidrome/navidrome/discussions/5154#discussioncomment-18927485)),
   whose maintainer plans this in Navidrome's own API, and to OpenSubsonic's app and server
   developers ([#283](https://github.com/opensubsonic/open-subsonic-api/discussions/283)).
5. Internet radios (Navidrome's `getInternetRadioStations`), in the app and in the protocol, so that
   a station moves between devices as a queue does: a queue item of `"kind": "radio"`, alone in its
   queue, with the station's `streamUrl` (Navidrome's Jellyfin API has no radios, so the id can't be
   translated) and what it plays now (ICY `StreamTitle`). It has no position, so no `seek`, `next`
   or `previous`; a `playsRadio` in the `hello` keeps it from apps that can't play it; the hub
   doesn't report it to the media server (section 12); and a player opens only `http` and `https`.

## License

MIT, see [LICENSE](LICENSE).
