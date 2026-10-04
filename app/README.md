<p align="center"><img src="linux/runner/resources/app_icon.png" alt="" width="128"></p>

# Segue app

A Spotify-like music player for Navidrome, any other OpenSubsonic server, or Jellyfin, built
around Segue Connect: you pick a device, and whatever you play goes there. One Flutter codebase for Linux,
Windows, macOS, Android and iOS. The interface is in Portuguese for now.

**Status: skeleton.** It does:
- signing in with the media server's own account, with only its address: the app finds out whether
  it speaks Subsonic (Navidrome, other OpenSubsonic servers) or Jellyfin (a Jellyfin server, or
  Navidrome's Jellyfin API at `/jellyfin`, experimental since Navidrome 0.64 and turned on with
  `ND_JELLYFIN_ENABLED=true`). The password isn't kept: the system's secure storage gets a Subsonic
  token, or Jellyfin's access token, which signing out ends on a Jellyfin server (Navidrome's keeps
  it until the password changes);
- albums (newest first) and artists (by name, each with their albums), in a side rail or, on a
  phone, a bar at the bottom; the album page; search (artists, albums and songs); and playback
  through media_kit (libmpv), with a seek bar, shuffle and repeat (the queue or the track), in the
  player bar and in a full-screen player that the song in the bar opens;
- the queue of whichever device the app controls, from the full-screen player or, on a wide
  screen, the player bar: the current track on top, the next ones under it and what played before
  above it. A tap on a track plays it there;
- on the album page and in search, the current song (on whichever device the app controls) stands
  out in the theme's color, with an equalizer in place of its number, or over its cover, while it
  plays;
- Connect: the hub is found next to the server (or typed in), and the device picker lists the
  user's other devices that are online, with what they play. Picking one makes the app control it
  (play, pause, skip, seek, shuffle, repeat, play an album there). Picking this device again moves the music here, at the
  same point. If the device it controls closes, its music stays here, paused. An app opened when
  nothing plays anywhere picks up where the music was.

- the system's media controls (through `audio_service`) show and command what the now-playing bar
  shows, the device it follows included: on Linux (MPRIS) the media keys, the desktop's player
  widget and KDE Connect; on iOS (Now Playing) the lock screen, Control Center, headphone buttons
  and CarPlay's Now Playing screen;
- on iOS, playing in the background and with the silent switch on; a call pauses the music, which
  plays again after it, and leaving the car or unplugging the headphones pauses it;
- its icon (made by `tool/icons.dart` from `tool/icon.png`): Android's launcher icon, adaptive from
  Android 8 on, the Android TV banner, on Linux the window's icon and an entry in the application
  menu, and the iOS icon.

Not yet: playlists, editing the queue (play next, add to it, reorder it), the media controls on the other platforms (Android's
media session), telling a Jellyfin server what plays (its sessions and play counts; on Subsonic
servers the hub does it), on a Jellyfin server the cover of a song that came from another device
when its file has none of its own (Jellyfin doesn't fall back to the album's), an offline cache, settings, and CarPlay as an app of its own (browsing the library
on the car's screen, which needs Apple's CarPlay entitlement and native code). The Android build
has been tried on a tablet and on an Android TV; the iOS build has not been tried on a device yet.

## Code

| Folder | What |
|---|---|
| `lib/server/` | `MediaServer`, what the app asks of the media server in either API, and its albums, artists and songs; finding out which API a server speaks, and signing in to it |
| `lib/subsonic/` | The Subsonic API: token sign-in, albums, artists, songs, search, stream and cover URLs |
| `lib/jellyfin/` | The Jellyfin API: sign-in by name for this device, the same library calls, and signing out |
| `lib/segue/` | The Segue protocol in Dart, the hub client (reconnects by itself) and hub discovery |
| `lib/player/` | `PlayerController` (queue, commands, state reports) over an `AudioEngine`; `MediaKitEngine` is the real one. `MediaControls`: the system's media controls. `AudioInterruptions`: calls and the like pausing the music, on iOS |
| `lib/connect/` | `ConnectController`: which device the app controls, and moving the music between devices |
| `lib/ui/` | The pages: sign-in, albums, artists, album, artist, search, player bar and full-screen player, queue, device picker |
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

Sign in with the media server's address (`https://` is added if left out), user and password.

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

Phones and tablets work the same way, through wireless debugging (Settings > About: press "Build
number" seven times, then Developer options > Wireless debugging). Its main screen shows the address
and port for `adb connect`; "Pair device with pairing code" shows another port, and the code, for
`adb pair`, which is needed once per computer:

```sh
adb pair <address>:<pairing port> <code>
adb connect <address>:<port>
adb install -r segue-android.apk
```

The port changes each time wireless debugging is turned on, and the address can change too when
the device rejoins the network. Over a slow Wi-Fi link the APK can take a while: copying it to the
device and opening it there (allowing that app to install apps) does the same.

## Running on iOS

The iOS version needs a Mac to build, so it is built on Codemagic's (`../codemagic.yaml`), which
signs it and uploads it to App Store Connect; the iPhone installs it from TestFlight. That takes a
paid Apple Developer Program membership. Codemagic's free plan has enough build minutes for a few
builds a week.

Once, on the web, with nothing to install:

1. In the Apple Developer site, under Certificates, Identifiers & Profiles, register the app's
   identifier: an explicit App ID `io.github.mateusguilherme.segue`, with no extra capabilities.
2. In App Store Connect, create the app with that bundle ID. Its name there has to be unique in the
   App Store; the home screen shows "Segue" whatever it is. In its TestFlight tab, make an internal
   testing group with yourself in it and automatic distribution on, so that each build reaches it.
3. In App Store Connect, under Users and Access > Integrations, make an App Store Connect API key
   with the App Manager role. Its `.p8` file downloads only once; note its Key ID and the Issuer ID.
4. In Codemagic, sign in with GitHub and add this repository. In the team's integrations, add the
   key under Developer Portal, named `segue` (the name `codemagic.yaml` asks for).
5. In Codemagic's code signing identities, generate an Apple Distribution certificate with that
   key. Then, in the Apple Developer site, make an App Store Connect provisioning profile for the
   App ID with that certificate, and fetch it in Codemagic.

Then each build starts from Codemagic's page (workflow "iOS to TestFlight") or by pushing a tag
starting with `ios-`:

```sh
git tag ios-1 && git push origin ios-1
```

It takes about 15 minutes, plus Apple's processing. The build then shows in the TestFlight app on the
iPhone, from the internal group's invitation, for 90 days. The first time the app reaches a server
in the local network, iOS asks for permission.

What iOS does differently:
- In the background, iOS keeps the app running only while it plays. Paused, or just controlling
  another device, it is suspended after a while, and the hub sees it leave until it is opened again.
- In a car, the music shows in CarPlay's Now Playing screen, with its controls, but the app has no
  screen of its own there.

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
