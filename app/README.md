<p align="center"><img src="linux/runner/resources/app_icon.png" alt="" width="128"></p>

# Segue app

A Spotify-like music player for Navidrome (or any OpenSubsonic server), built around Segue
Connect: you pick a device, and whatever you play goes there. One Flutter codebase for Linux,
Windows, macOS, Android and iOS. The interface is in Portuguese for now.

**Status: skeleton.** It does:
- signing in with the media server's own account, with the password kept as a Subsonic token in
  the system's secure storage;
- albums (newest first) and artists (by name, each with their albums), in a side rail or, on a
  phone, a bar at the bottom; the album page; search (artists, albums and songs); and playback
  through media_kit (libmpv), with a seek bar, shuffle and repeat (the queue or the track), in the
  player bar and in a full-screen player that the song in the bar opens;
- Connect: the hub is found next to the server (or typed in), and the device picker lists the
  user's other devices that are online, with what they play. Picking one makes the app control it
  (play, pause, skip, seek, shuffle, repeat, play an album there). Picking this device again moves the music here, at the
  same point. If the device it controls closes, its music stays here, paused. An app opened when
  nothing plays anywhere picks up where the music was.

- the system's media controls on Linux (MPRIS, through `audio_service`): media keys, the
  desktop's player widget and KDE Connect show and command what the now-playing bar shows, the
  device it follows included;
- its icon (made by `tool/icons.dart` from `tool/icon.png`): Android's launcher icon, adaptive from
  Android 8 on, the Android TV banner, and on Linux the window's icon and an entry in the
  application menu.

Not yet: playlists, the queue on screen, the media controls on the other
platforms (Android's media session, iOS's Now Playing), an offline cache, settings, and the
iOS build. The Android build (phones and Android TV) has not been tried on a device yet.

## Code

| Folder | What |
|---|---|
| `lib/subsonic/` | The Subsonic API: token sign-in, albums, artists, songs, search, stream and cover URLs |
| `lib/segue/` | The Segue protocol in Dart, the hub client (reconnects by itself) and hub discovery |
| `lib/player/` | `PlayerController` (queue, commands, state reports) over an `AudioEngine`; `MediaKitEngine` is the real one. `MediaControls`: the system's media controls |
| `lib/connect/` | `ConnectController`: which device the app controls, and moving the music between devices |
| `lib/ui/` | The pages: sign-in, albums, artists, album, artist, search, player bar and full-screen player, device picker |
| `test/` | Unit and widget tests, and tests against the real Go hub (`hub_test.dart`) |
| `tool/` | A Docker image and script to build and test without installing Flutter; `icons.dart` makes every icon from the artwork, `icon.png` |

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

`segue/install-desktop-entry.sh` puts Segue in the application menu, with its icon: it writes
`~/.local/share/applications/io.github.mateusguilherme.segue.desktop`, pointing at the folder (run
it again after moving the folder). On Wayland the window takes its icon from that file, so without
it the window has a generic one.

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
env SEGUE_DEVICE_ID=second SEGUE_DEVICE_NAME="Second copy" segue/segue
```

## Running on Android and Android TV

`tool/package-android.sh` builds `build/segue-android.apk` (with Flutter and the Android SDK from
Docker, see below): one APK for every processor, signed with a debug key, to install by hand. On
Android TV the app is in the home screen, and the remote drives it: the D-pad moves around (its
center button presses, and a white ring shows where it is), and the play/pause, next and previous
buttons drive playback.

To install it from a computer with adb (`android-tools` on Fedora), turn on the TV's developer
options (Settings > Device Preferences > About: press "Build" seven times) and, in them, network
debugging. Then:

```sh
adb connect <TV address>
adb install -r segue-android.apk
```

Newer Google TVs offer wireless debugging instead: `adb pair` with the address and code the TV
shows, then `adb connect`. The TV has to reach the media server (and the hub) at the address used
to sign in.

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

After changing the artwork (`tool/icon.png`), `DART=1 tool/flutter.sh run tool/icons.dart` makes
the icons again. The rounded square's position in the artwork is measured at the top of
`tool/icons.dart`, so a new artwork needs it measured again.

For Android, a second image adds the JDK and the Android SDK and NDK to the first:

```sh
docker build -t segue-flutter-android -f tool/android.Dockerfile tool
tool/package-android.sh
```
