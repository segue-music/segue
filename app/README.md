# Segue app

A Spotify-like music player for Navidrome (or any OpenSubsonic server), built around Segue
Connect: you pick a device, and whatever you play goes there. One Flutter codebase for Linux,
Windows, macOS, Android and iOS. The interface is in Portuguese for now.

**Status: skeleton.** It does:
- signing in with the media server's own account, with the password kept as a Subsonic token in
  the system's secure storage;
- an album grid (newest first), the album page, search (albums and songs, by name, title or
  artist), and playback through media_kit (libmpv);
- Connect: the hub is found next to the server (or typed in), and the device picker lists the
  user's other devices that are online, with what they play. Picking one makes the app control it
  (play, pause, skip, play an album there). Picking this device again moves the music here, at the
  same point. An app opened when nothing plays anywhere picks up where the music was.

- the system's media controls on Linux (MPRIS, through `audio_service`): media keys, the
  desktop's player widget and KDE Connect show and command what the now-playing bar shows, the
  device it follows included.

Not yet: artists, playlists, a full-screen player, the media controls on the other
platforms (Android's media session, iOS's Now Playing), an offline cache, settings, and the
Android and iOS builds.

## Code

| Folder | What |
|---|---|
| `lib/subsonic/` | The Subsonic API: token sign-in, albums, songs, search, stream and cover URLs |
| `lib/segue/` | The Segue protocol in Dart, the hub client (reconnects by itself) and hub discovery |
| `lib/player/` | `PlayerController` (queue, commands, state reports) over an `AudioEngine`; `MediaKitEngine` is the real one. `MediaControls`: the system's media controls |
| `lib/connect/` | `ConnectController`: which device the app controls, and moving the music between devices |
| `lib/ui/` | The pages: sign-in, albums, album, search, now-playing bar, device picker |
| `test/` | Unit and widget tests, and tests against the real Go hub (`hub_test.dart`) |
| `tool/` | A Docker image and script to build and test without installing Flutter |

## Running on Linux

### A build from elsewhere, without Flutter

`tool/package-linux.sh` builds the Linux version (with Flutter from Docker, see below) and packs
it as `build/segue-linux-x64.tar.gz`, 10 MB. The computer that runs it needs glibc 2.38 or newer,
GTK 3, libsecret and libmpv, all runtime packages. On Fedora (checked on Fedora 44):

```sh
sudo dnf install gtk3 libsecret mpv-libs
tar xzf segue-linux-x64.tar.gz
segue/segue
```

### With Flutter installed

Install Flutter 3.47 ([instructions](https://docs.flutter.dev/get-started/install/linux)) and
what the Linux build needs: clang, cmake, make, ninja, pkg-config, GTK 3, liblzma and libstdc++
headers, plus the headers of libmpv (audio) and libsecret (secure storage). On Fedora that should
be the following (check the names with `dnf search` if one is missing):

```sh
sudo dnf install clang cmake make ninja-build pkgconf-pkg-config gtk3-devel xz-devel \
  libstdc++-devel mpv-libs-devel libsecret-devel jsoncpp-devel
cd app
flutter pub get
flutter run -d linux
```

Sign in with the Navidrome address (`https://` is added if left out), user and password.

### Connect

Connect needs the hub (`../hub`). Published at `/connect` on the media server's address, it is
found by itself, with nothing to type at sign-in. To try it without that, run it on your computer,
pointing at the media server:

```sh
cd hub
go build -o segue-hub ./cmd/segue-hub
env SEGUE_UPSTREAM=https://navidrome.example ./segue-hub
```

and at sign-in, under "Avançado", put `http://127.0.0.1:8480` as the hub's address. The hub's
binary is static, so one built elsewhere (`../hub/segue-hub` on the server) runs as it is.

To see two devices on one computer, start a second copy of the app as another device:

```sh
env SEGUE_DEVICE_ID=second SEGUE_DEVICE_NAME=Segundo segue/segue
```

## Building and testing without Flutter installed

`tool/flutter.sh` runs Flutter from a Docker image, as your user. The tests against the hub need
its binary built first (`go build -o segue-hub ./cmd/segue-hub` in `../hub`).

```sh
docker build -t segue-flutter-dev -f tool/dev.Dockerfile tool
tool/flutter.sh pub get
tool/flutter.sh analyze
tool/flutter.sh test
tool/flutter.sh build linux
tool/package-linux.sh
```
