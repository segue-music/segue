<p align="center"><img src="app/linux/runner/resources/app_icon.png" alt="" width="128"></p>

# Segue

A draft of an open "Connect" protocol for music apps that use OpenSubsonic (Navidrome and others)
or Jellyfin, with a reference hub. With it, each of your devices can see what the others are
playing, control any of them, and move the music from one to another, like Spotify Connect, but
across apps and servers.

Apps can't be commanded by anything on the server side unless they listen for it, so this is a
protocol that apps implement once, plus a small hub that runs next to the media server. The hub
signs devices in with the credentials they already use with the media server, keeps the state of
each player, and routes commands. Audio still comes from the media server. The problem, the design
and the messages are in [SPEC.md](SPEC.md).

**Status: skeleton.** The protocol is a first draft. The hub works in its tests and with the
first client, an app of its own (`app/`); both have run next to a real Navidrome since 2026-10-03.

## Layout

| Folder | What |
|---|---|
| `SPEC.md` | The protocol |
| `hub/` | The reference hub, in Go. Package `hub` (usable as a library), binary in `cmd/segue-hub` |
| `app/` | A Spotify-like player for Navidrome built on Segue, in Flutter (Linux, Windows, macOS, Android, iOS). See [app/README.md](app/README.md) |

The hub is in Go, the language of Navidrome, so that it can move into a media server. It also
uses the same WebSocket library as Navidrome (`gorilla/websocket`). As a separate service it is
one static binary: an 11 MB image, using about 2 MB of RAM when idle.

The app's side of the protocol is in Dart (`app/lib/segue/`). A client in another language follows
`SPEC.md`. A reference client in TypeScript, for apps like Feishin and Jellify, lived in `client/`
until 2026-10-03: `git checkout c22dc7b -- client` brings it back.

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
| `SEGUE_UPSTREAM` | (required) | The media server's URL, as the hub reaches it |
| `SEGUE_UPSTREAM_KIND` | `navidrome` | `navidrome` (Subsonic API, Jellyfin API at `/jellyfin`, ids translated), `subsonic` or `jellyfin` |
| `SEGUE_LISTEN` | `127.0.0.1:8480` | Address and port |
| `SEGUE_STATE` | | A file where each user's last playback is kept across restarts (SPEC, section 7). Empty keeps it in memory only |
| `SEGUE_AUTH` | | `none` accepts any device, as the Subsonic user it claims (`dev` for other schemes). Only for trying things out |

Clients find the hub at `/connect/` on the media server's origin, so route that path there in the
reverse proxy. It must be `https`, because devices send their credentials.

With Docker: `docker build -t segue-hub hub/`, then run it with the variables above. The image
listens on `0.0.0.0:8480`.

## Next steps

1. The app: playlists, the queue on screen, and trying the Android build on a phone and a TV (see
   [app/README.md](app/README.md)).
2. An observer that lists apps that don't speak the protocol (from `getNowPlaying`), as devices that
   can be seen but not commanded. That covers apps like Symfonium, which is closed source.
3. Check, once an app on the Jellyfin API speaks the protocol, that Navidrome's two APIs give the
   same user names and that the ids translate on real items.
4. Propose it: an OpenSubsonic discussion (next to
   [#277](https://github.com/opensubsonic/open-subsonic-api/discussions/277)), Navidrome, and the
   open-source apps.

## License

MIT, see [LICENSE](LICENSE).
