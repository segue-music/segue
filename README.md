<p align="center"><img src="icon.png" alt="" width="160"></p>

<h1 align="center">Segue</h1>

<h3 align="center">Connect for self-hosted music.</h3>

<p align="center">
  Each of your devices sees what the others are playing, controls any of them, and moves the music
  from one to another without losing its place, across apps and servers. A draft of an open
  protocol for apps on OpenSubsonic (Navidrome and others) or Jellyfin, and its reference hub,
  which runs next to the media server.
</p>

<p align="center">
  <a href="#running-the-hub">Running the hub</a> ·
  <a href="SPEC.md">Protocol</a> ·
  <a href="IMPLEMENTING.md">Implementing it in an app</a> ·
  <a href="#next-steps">Next steps</a>
</p>

> [!NOTE]
> **Vibe-coded.** The spec and the hub were written by Claude (through Claude Code), with a person
> deciding what to build and trying it on real devices. Every commit says so.

---

Apps can't be commanded by anything on the server side unless they listen for it. Segue is a
protocol they implement once, and the hub is what they connect to: a small service next to the
media server, which needs nothing changed in it.

```
 phone app ──┐                      ┌── checks credentials ──► media server
 TV app    ──┼── WebSocket ── hub ──┘                          (Navidrome, Jellyfin, ...)
 desktop   ──┘                                                       ▲
     └────────────── audio, straight from the media server ──────────┘
```

The hub:

- signs devices in with the credentials they already use with the media server, by asking it, so
  it keeps no users or passwords of its own;
- keeps each user's devices and the last state of each player, and relays it to their other
  devices. A device that goes offline stays listed, with its last state, for 24 hours;
- routes commands to players, and moves the music from one device to another, at the same point and
  in the same modes, even from a device that is offline;
- translates item ids between Navidrome's Subsonic and Jellyfin APIs, so that devices on either
  share a queue;
- keeps each user's last playback, so that an app opened when nothing plays picks up where the music
  was;
- tells the media server what each device plays, so that its now playing lists them by name.

Audio doesn't go through the hub: devices still play from the media server. How it all works is in
[SPEC.md](SPEC.md).

**Status: early.** The protocol is a first draft. The hub passes its tests and has run next to a
real Navidrome since 2026-10-03. On Jellyfin, and on Navidrome's Jellyfin API, it has run only in
its tests.

## Apps

So far one app speaks Segue: [segue-app](https://github.com/segue-music/segue-app), a music player
for Navidrome, other OpenSubsonic servers and Jellyfin. Another app follows [SPEC.md](SPEC.md), and
[IMPLEMENTING.md](IMPLEMENTING.md) walks through it, in the order an app developer builds it. With
`SEGUE_AUTH=none`, the hub needs no media server, for trying an app against it
([Try it](IMPLEMENTING.md#10-try-it)).

## Running the hub

The hub runs next to the media server, behind the same reverse proxy, by the same admin, since
devices send it their credentials.

### With Docker

The image `ghcr.io/segue-music/segue-hub`, for amd64, arm64 and armv7, listens on `0.0.0.0:8480`
and keeps the last playbacks in `/data` (`SEGUE_STATE=/data/state.json`). `SEGUE_MEDIA_SERVER_URL`
is the media server as the container reaches it, such as by its name on a network they share:

```sh
docker run -d --name segue-hub --restart unless-stopped --network <the media server's network> \
  -p 127.0.0.1:8480:8480 -v segue-hub:/data -e SEGUE_MEDIA_SERVER_URL=http://navidrome:4533 \
  ghcr.io/segue-music/segue-hub
```

A named volume, as here, keeps the last playbacks when the container is made again; a folder of the
host mounted at `/data` instead has to be one that user 65532, the image's, can write. Each push to
`main` that changes the hub publishes the image again, once its tests pass, as `latest` and as
`sha-<commit>` (`.github/workflows/hub-image.yml`).

The image holds the static binary and CA certificates, nothing else: 11 MB, using about 2 MB of
RAM when idle.

### From source

Needs Go 1.27.

```sh
cd hub
go test -race ./...
go build -o segue-hub ./cmd/segue-hub
SEGUE_MEDIA_SERVER_URL=http://127.0.0.1:4533 ./segue-hub
```

`docker build -t segue-hub hub/` builds the image from this repository.

### Configuration

| Variable | Default | |
|---|---|---|
| `SEGUE_MEDIA_SERVER_URL` | (required, except with `SEGUE_AUTH=none`) | The media server's URL, as the hub reaches it. The hub asks it at startup, until it answers, whether it is Navidrome (Subsonic API, Jellyfin API at `/jellyfin`, ids translated), another Subsonic server or Jellyfin. Its old name, `SEGUE_UPSTREAM`, still works for now, with a warning in the log |
| `SEGUE_LISTEN` | `127.0.0.1:8480` | Address and port |
| `SEGUE_STATE` | | A file where each user's last playback is kept across restarts (SPEC, section 7). Empty keeps it in memory only |
| `SEGUE_AUTH` | | `none` accepts any device, as the Subsonic user it claims (`dev` for other schemes). Only for trying things out, and then without a media server if `SEGUE_MEDIA_SERVER_URL` is empty. Of the pages in a browser, only those served from the same machine (`localhost`) find it and connect, since any other could then act as anyone |

The hub logs to standard output. Stopping it (`SIGTERM`, as `docker stop` sends) closes every
device's connection first, so that apps reconnect as soon as it is back, and writes the last
playbacks.

### Behind the reverse proxy

Apps find the hub at `/connect/` on the media server's origin (SPEC, section 1), so the reverse
proxy routes that path to it, its WebSocket too. It must be `https`, because devices send their
credentials. The hub answers there whether the proxy strips the prefix or not. With Caddy, next to
Navidrome:

```caddyfile
music.example {
	handle /connect/* {
		reverse_proxy 127.0.0.1:8480
	}
	handle {
		reverse_proxy 127.0.0.1:4533
	}
}
```

With nginx, in the media server's `server` block:

```nginx
location /connect/ {
    proxy_pass http://127.0.0.1:8480;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
}
```

The hub sends the CORS headers of `/connect/v1/info` itself, for apps in a browser, so the proxy
mustn't add its own there: a browser refuses `Access-Control-Allow-Origin` given twice. In nginx, a
`location` with no `add_header` of its own inherits those of the `server` block, such as an
`add_header Access-Control-Allow-Origin` for the media server's web players.

Elsewhere, at the root of a host of its own say, the hub answers too, but apps find it there only
if the user types its URL.

### What the media server sees

The hub asks the media server about each device that signs in, and keeps a success for 5 minutes.
It holds a device's credentials in memory only, while the device is connected, to tell the media
server what it plays (SPEC, section 12), so Navidrome's Now Playing and Jellyfin's sessions show
Segue's devices by name. In the Subsonic API it uses OpenSubsonic's `reportPlayback` (Navidrome
0.62 and later) where the server has it, and counts no plays. In Jellyfin's it uses the sessions
API, and Jellyfin counts a play for each track that starts from its start. With `SEGUE_AUTH=none`
it reports nothing.

## In Go

The hub is in Go, the language of Navidrome, so that it can move into a media server (SPEC, section
13), and uses the same WebSocket library (`gorilla/websocket`). Package `hub` is usable as a
library: its checks, id translation and reports are pluggable (`Authenticate`, `Translate` and
`Report` in its `Options`), and `Handler` serves it, under `/connect/` or at the root.
`hub/cmd/segue-hub` is the binary above, configured by its environment.

## Next steps

1. An observer that lists apps that don't speak the protocol (from `getNowPlaying`, leaving out what
   the hub reports itself), as devices that can be seen but not commanded. That covers apps like
   Symfonium, which is closed source.
2. Run the hub against a real Jellyfin server and Navidrome's Jellyfin API: that Navidrome's two
   APIs give the same user names, and that the ids translate on real items.
3. Propose it to the open-source apps. It went to Navidrome as design input
   ([#5154](https://github.com/navidrome/navidrome/discussions/5154#discussioncomment-18927485)),
   whose maintainer plans this in Navidrome's own API, and to OpenSubsonic's app and server
   developers ([#283](https://github.com/opensubsonic/open-subsonic-api/discussions/283)).
4. Internet radios (Navidrome's `getInternetRadioStations`) in the protocol, so that a station
   moves between devices as a queue does: a queue item of `"kind": "radio"`, alone in its
   queue, with the station's `streamUrl` (Navidrome's Jellyfin API has no radios, so the id can't be
   translated) and what it plays now (ICY `StreamTitle`). It has no position, so no `seek`, `next`
   or `previous`; a `playsRadio` in the `hello` keeps it from apps that can't play it; the hub
   doesn't report it to the media server (section 12); and a player opens only `http` and `https`.

## License

MIT, see [LICENSE](LICENSE).
