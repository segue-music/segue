# Implementing Segue in an app

For developers adding Segue to a music app for OpenSubsonic or Jellyfin. [SPEC.md](SPEC.md) is the
protocol, and this guide doesn't replace it: it puts the app's side in the order you build it, links
each rule to its section, and adds what the reference app
([segue-app](https://github.com/segue-music/segue-app)) does where the protocol leaves a choice.
Where the two disagree, SPEC.md is right and this guide has a bug.

## What it takes

A device is a **controller**, a **player**, or both ([overview](SPEC.md#overview)):

| Role | Your app | Messages |
|---|---|---|
| Controller | Shows the user's other devices and what they play, and commands them | Sends `hello`, `command`, `transfer`. Receives `welcome`, `device`, `state`, `gone`, `result` |
| Player | Reports what it plays and obeys commands | Sends `hello`, `state`, `result`. Receives `welcome`, `command` |
| Both | Everything above, and can take the music from another device ("continue here") | All of them |

Audio still comes from the media server, with the ids the app already uses. The hub only relays
messages. The reference app's whole side of the protocol, discovery, messages and connection, is
about 700 lines of Dart (`lib/segue/`), plus 360 for the behaviour in [section 7](#7-behave-like-the-other-apps)
(`lib/connect/connect.dart`).

## 1. Find the hub

[SPEC, section 1](SPEC.md#1-discovery).

- Probe `B/connect/v1/info`, where `B` is the media server's base URL, then `/connect/v1/info` on
  `B`'s origin if `B` has a path. A hub answers `200` with `"protocol": "segue"` and a `versions`
  list that has `1`. Its WebSocket is `connect/v1/ws` next to it, `wss://` for `https://`.
- Probe once per sign-in, with a short timeout (the reference app gives each URL 3 s).
- Let the user type a hub URL instead, for servers whose proxy doesn't route `/connect/`.
- No hub: the app works as it did. Segue is an addition, never a requirement.

## 2. Connect and say hello

[SPEC, section 2](SPEC.md#2-connection-and-authentication).

`hello` is the first message. The choices in it that matter:

- **`auth`**: the credentials the app already sends to the media server. Subsonic's token and salt
  (not `p=`), an OpenSubsonic API key, or a Jellyfin access token.
- **`device.id`**: generate a UUID once per installation and keep it, also across sign-outs. Two
  copies of the app must never share one: the hub closes the older connection (4003).
- **`device.name`**: what the other apps show. The system's device name ("Living room TV") is a good
  default, and the user may want to change it.
- **`device.api`**: the API your app speaks. Every id you send and receive is in it.
- **`roles`** and **`capabilities`**: declare only the commands you obey. The hub doesn't send the
  others (the controller gets `unsupported`). Two of them matter more than they look:
  - without `setQueue`, a device can't receive a transfer;
  - without `stop`, the hub sends `pause` when another device starts, and your app is left
    paused with music that plays elsewhere.
- **`reportsPlayback`**: see [section 8](#8-tell-the-media-server).
- **Jellyfin apps**: use the Segue `device.id` as the `DeviceId` you send to Jellyfin. The hub signs
  its reports with it, so Jellyfin shows them as your device's ([SPEC, section 12](SPEC.md#12-the-media-servers-now-playing)).

From `welcome`, keep:

- the clock offset, `serverTime` minus local time, to compute positions ([section 3](#3-keep-the-device-list));
- `devices`, the user's other devices with their last state;
- `lastPlayback`, if there is one ([section 7](#7-behave-like-the-other-apps)).

Then, if you are a player, report your full state ([section 4](#4-report-as-a-player)).

## 3. Keep the device list

[SPEC, sections 3 and 4](SPEC.md#3-devices).

- `device`: replace what you had for that id. `gone`: remove it.
- `state`: **merge** it into what you had. `status`, `positionMs` and `at` are always there; a field
  left out keeps its value. A player sends `queue` only when it changed, so replacing the state
  loses the queue.
- Where a device is now: `positionMs + (hubNow - at)` while `playing`, `positionMs` otherwise, with
  `hubNow` the local time plus the offset from `welcome`. The reference app never lets
  `hubNow - at` go negative, and stops at the track's `durationMs`.
- Offline devices stay listed, `paused`, with their last queue. They can't take commands (`offline`),
  but they can be the source of a transfer. The reference app's device picker lists only online
  players.
- A queue item may come without `id`, when the hub couldn't translate it to your API
  ([SPEC, section 8](SPEC.md#8-ids-across-apis)). Show it from its metadata.

## 4. Report as a player

[SPEC, section 4](SPEC.md#4-player-state-and-the-clock).

- Report on every change: another track, play, pause, stop, a seek, the queue, volume, repeat,
  shuffle. There is no need to report periodically: the other apps compute the position.
- Every report has `status` and `positionMs`. `stopped` means nothing is loaded.
- `queue` is in play order (after shuffling), with title, artist, album and `durationMs` so that the
  other apps show it without a lookup. Send it when it changed, and in full after every
  (re)connection, since the hub may have restarted. Shuffled, send `order` with it, each item's place
  unshuffled, so that the device a transfer takes the queue to can turn shuffle off as you would.
- Watch for changes your audio engine doesn't signal. In the reference app, seeking and starting
  the current track over had to report explicitly.
- On mobile, a paused app in the background gets suspended. Report the pause as it happens, and
  the other apps keep your queue to pick up ([SPEC, section 9](SPEC.md#9-liveness-and-mobile-apps)).
- A controller-only device doesn't report (the hub answers `notPlayer`).

## 5. Obey commands as a player

[SPEC, sections 5 and 6](SPEC.md#5-commands).

- Answer every `command` with a `result` whose `re` is the command's `id`, and report your new
  state. The hub gives up after 10 s (`timeout`).
- When you can't carry out a command, answer `"ok": false` with an `error` of your own: the
  controller shows it to the user.
- Follow the table in SPEC section 5 exactly. Apps differ here, and the user notices:
  - `next` after the last track wraps around only when `repeat` isn't `off`;
  - `previous` restarts the track, except in its first 3 seconds, and always on the first track;
  - `jump` to the current track starts it over.
- `setQueue` is how a transfer arrives: a queue, an index, a position, and whether to play.
  - Items may come without `id`. The reference app drops them, and moves `index` back by those it
    dropped before it, so that the same track stays current. With nothing playable left, it fails.
  - A transfer brings the modes the source played in: `repeat`, and `shuffle` with its `order`.
    Shuffled, play `queue` as it comes, without shuffling it again, and keep `order` (dropping the
    places of the items you dropped) for when shuffle goes off. Without them, keep your own.
  - After `setShuffle`, report the new `queue`.
- `addToQueue` adds items without touching the current track: right after it with `next`, otherwise
  at the end. Items without `id` are dropped as in `setQueue`; with none left, it fails. A player
  with no queue takes them as its queue, paused. Report the new `queue`.
- `moveInQueue` and `removeFromQueue` go by places in `queue`, as you last reported it, and leave the
  current track playing, wherever a move takes it. Shuffled, a move changes the play order alone, which
  turning shuffle off forgets. Fail on a place past the queue (the reference app says `no such track`),
  and on removing the current track (`current track`). Report the new `queue`.
- **The hub's `stop`.** When another of the user's devices starts playing, the hub sends you
  `stop`, as a command from that device ([SPEC, section 4](SPEC.md#4-player-state-and-the-clock)).
  Obey it like any other: leave the player idle, with no queue, and report `stopped`. Paused with the
  old queue, your device would show as paused with music that now plays elsewhere.

## 6. Command as a controller

[SPEC, sections 5 and 6](SPEC.md#5-commands).

- Send `command` with an `id` of your own, and match the `result` by `re`.
- Draw the other device from its `state` reports, not from the `result`: the result says the
  command was carried out, and the report that follows says what changed.
- Disable the controls the player didn't declare in `capabilities` (repeat, shuffle, picking a track
  from the queue, adding to it, moving and removing its tracks).
- Turn the hub's errors into words for the user (`offline`, `timeout`, `unsupported`,
  `nothingToTransfer`...). The reference app's `describeError` (`lib/ui/errors.dart`) is a list of them.
- `transfer` moves the music. `to` can be your own device ("continue here"), and `from` can be
  offline, since its last state is enough.

## 7. Behave like the other apps

The protocol doesn't say how an app should present all this. When every app does it the same way,
the user can move between apps without surprises. This is what the reference app does
(`lib/connect/connect.dart`):

- **One device at a time.** The app controls one device, itself or another, and every control
  goes to it: play an album, pause, skip.
- **Picking another device moves the music.** If the current one has a queue, a `transfer` from it to
  the new one; otherwise just a switch.
- **Follow the device that plays.** When a device starts playing, the app switches to it. The one that
  plays is this device if it plays; otherwise the online device whose `playing` report is the most
  recent (the largest `at`).
- **Drop paused music when another device starts.** The hub stops a device that was playing, but not
  one that was paused. The reference app stops its own player when another device starts and it
  holds a paused queue.
- **Keep the music when the controlled device goes away.** When the device the app controls goes
  offline, the app loads its queue here, paused where it got to, instead of losing it from the
  screen.
- **Show the last playback on opening.** On the first connection after the app opens, not on
  reconnections, if nothing plays anywhere and nothing is loaded here, it shows `lastPlayback`
  ([SPEC, section 7](SPEC.md#7-last-playback)). If another online device holds it, the app
  controls that device. Otherwise it loads the queue here, paused at the same point, so that play
  continues it. Loading it doesn't take it over.

## 8. Tell the media server

[SPEC, section 12](SPEC.md#12-the-media-servers-now-playing). The hub can fill the media server's now
playing for your device, so pick one of two ways:

- **Let the hub do it** (leave `reportsPlayback` out). Stop sending now playing yourself:
  `reportPlayback`, `scrobble` with `submission=false`, Jellyfin's `Sessions/Playing`.
  - Subsonic API: count plays yourself, with `scrobble` and `submission=true`.
  - Jellyfin API: count nothing. The hub's `Sessions/Playing` counts.
- **Keep doing it** (`"reportsPlayback": true`). The hub then reports nothing for you, and counting
  stays yours.

Either way, a track can now arrive by a transfer, halfway through. Count plays by how long the track
played on this device, not by where it got to, or a moved track counts on both devices. The reference
app counts a track once it has played half its length or four minutes, whichever comes first,
added up across pauses and seeks (`lib/player/play_counter.dart`). If you keep reporting to
Jellyfin yourself, every `Sessions/Playing` counts a play. The hub sends `Sessions/Playing/Progress`
for a track it hears of halfway, which shows it without counting.

## 9. Stay connected

[SPEC, sections 2 and 9](SPEC.md#9-liveness-and-mobile-apps).

- Reconnect with backoff. The reference app starts at 1 s, doubles up to 30 s, and starts over after
  a connection the hub accepted.
- Don't reconnect after 4001 (wrong credentials, until they change), 4002 (no valid `hello`) or
  4003. That includes a 4003 after the hub accepted you: two copies that kept reconnecting would
  take turns kicking each other out.
- Fail the requests still waiting for an answer when the connection closes.
- The hub pings every 30 s. WebSocket libraries usually answer by themselves.
- Log the hub's `error` messages: each says that a message of yours had no effect, and why
  ([SPEC, section 2](SPEC.md#2-connection-and-authentication)).
- Ignore message types, fields and capabilities you don't know, so that your app keeps working
  with a newer hub.

## 10. Try it

A hub with `SEGUE_AUTH=none` needs no media server, and accepts any device as the Subsonic user it
names. Build it as in the [README](README.md#hub) and run:

```sh
SEGUE_AUTH=none ./segue-hub
```

Type `http://127.0.0.1:8480` as the hub's URL in your app, and sign in as some user, `alice`
say. With any WebSocket client ([websocat](https://github.com/vi/websocat), for instance), you can
then be alice's other device, one message per line:

```sh
websocat ws://127.0.0.1:8480/v1/ws
```

As a controller, to command your app. Its id comes in the `welcome`, or in a `device` message if
your app connects later:

```json
{"type":"hello","protocol":1,"auth":{"scheme":"subsonic","username":"alice","token":"x","salt":"y"},"device":{"id":"laptop","name":"laptop","client":"test","api":"subsonic","roles":["controller"],"capabilities":[]}}
{"type":"command","id":"r1","target":"<your app's id>","command":{"action":"pause"}}
```

As a player, to move the music to it from your app. Reporting `playing` stops your app, if it plays.
Commands then arrive here, a `stop` when your app starts playing, a `setQueue` when it moves the music
here, and you answer each by hand:

```json
{"type":"hello","protocol":1,"auth":{"scheme":"subsonic","username":"alice","token":"x","salt":"y"},"device":{"id":"laptop","name":"laptop","client":"test","api":"subsonic","roles":["player"],"capabilities":["play","pause","stop","setQueue"]}}
{"type":"state","state":{"status":"playing","positionMs":0,"index":0,"queue":[{"id":"<a song id on your server>","title":"Song","durationMs":200000}]}}
{"type":"result","re":"<the command's id>","ok":true}
```

For a real device on the other side, run [segue-app](https://github.com/segue-music/segue-app). On a
computer, two copies with the same login are two devices when they have different
`SEGUE_DEVICE_ID` and `SEGUE_DEVICE_NAME` environment variables.

Cases worth trying:

- moving the music both ways, from another app to yours and back, mid-track;
- starting on one device while another plays: the other stops;
- closing the app while it plays: the others list it paused, offline, and can take its queue;
- on mobile, pausing and leaving the app in the background, then taking its queue from another device;
- restarting the hub: the app reconnects and reports again;
- a track whose id the other app's API doesn't have.

## Reference code

| | |
|---|---|
| [`lib/segue/discovery.dart`](https://github.com/segue-music/segue-app/blob/main/lib/segue/discovery.dart) | Finding the hub |
| [`lib/segue/protocol.dart`](https://github.com/segue-music/segue-app/blob/main/lib/segue/protocol.dart) | The messages, merging states, the position now |
| [`lib/segue/client.dart`](https://github.com/segue-music/segue-app/blob/main/lib/segue/client.dart) | The connection: hello, reconnection, commands and results |
| [`lib/player/player.dart`](https://github.com/segue-music/segue-app/blob/main/lib/player/player.dart) | Obeying commands and reporting (`obey`, `report`) |
| [`lib/connect/connect.dart`](https://github.com/segue-music/segue-app/blob/main/lib/connect/connect.dart) | The behaviour in section 7 |
| [`lib/player/play_counter.dart`](https://github.com/segue-music/segue-app/blob/main/lib/player/play_counter.dart) | Counting plays by time played |
| [`hub/protocol.go`](hub/protocol.go) | The same messages, on the hub's side |
