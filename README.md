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

**Status: skeleton.** The protocol is a first draft, and the hub works in tests and in the demo,
with pretend players. No real app speaks it yet.

## Layout

| File | What |
|---|---|
| `SPEC.md` | The protocol |
| `src/protocol.ts` | Message types and parsers, shared by hub and client |
| `src/hub.ts` | The hub: devices per user, state relay, commands, transfer |
| `src/server.ts` | HTTP and WebSocket: `GET /v1/info`, `/v1/ws` (also under `/connect/`) |
| `src/auth.ts` | Checks credentials with the media server |
| `src/ids.ts` | Translates Navidrome ids between the Subsonic and Jellyfin APIs |
| `src/client.ts` | Reference client. Uses only the standard WebSocket API, so it runs in browsers, Node and React Native |
| `src/main.ts` | Runs the hub from environment variables |
| `examples/` | A pretend player, and a demo moving music from an "iPhone" to a "TV" |

## Trying it

Needs Node 24 or later, which runs the TypeScript files directly.

```sh
npm install
npm run demo        # hub + iPhone (Jellyfin API) + TV (Subsonic API) + PC; the PC moves the music
npm test
npm run typecheck
```

## Running

| Variable | Default | |
|---|---|---|
| `SEGUE_UPSTREAM` | (required) | The media server's URL, as the hub reaches it, e.g. `http://127.0.0.1:4533` |
| `SEGUE_UPSTREAM_KIND` | `navidrome` | `navidrome` (Subsonic API, Jellyfin API at `/jellyfin`, ids translated), `subsonic` or `jellyfin` |
| `SEGUE_LISTEN` | `127.0.0.1:8480` | Address and port |
| `SEGUE_AUTH` | | `none` accepts any device as the user `dev`. Only for trying things out |

```sh
SEGUE_UPSTREAM=http://127.0.0.1:4533 npm start
```

Clients find the hub at `/connect/` on the media server's origin, so route that path there in the
reverse proxy (it must be `https`, since devices send their credentials).

With Docker: `docker build -t segue .`, then run it with the variables above and
`SEGUE_LISTEN=0.0.0.0:8480`, which is the image's default.

## Next steps

1. Run it next to a real Navidrome: confirm that the Jellyfin and Subsonic APIs give the same user
   names, and that the ids translate on real items.
2. An observer that lists apps that don't speak the protocol (from `getNowPlaying`), as devices that
   can be seen but not commanded. That covers apps like Symfonium, which is closed source.
3. A first real app, as player and controller. Feishin (TypeScript, open source) is the closest
   fit for `src/client.ts`.
4. Propose it: an OpenSubsonic discussion (next to
   [#277](https://github.com/opensubsonic/open-subsonic-api/discussions/277)), Navidrome, and the
   open-source apps.
