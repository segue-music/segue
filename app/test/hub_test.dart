// The app's Segue client and ConnectController against the real (Go) hub. Needs the hub binary
// (go build -o segue-hub ./cmd/segue-hub in ../hub, or its path in SEGUE_HUB_BIN).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:segue/connect/connect.dart';
import 'package:segue/player/media_controls.dart';
import 'package:segue/player/player.dart';
import 'package:segue/segue/client.dart';
import 'package:segue/segue/protocol.dart';
import 'package:segue/subsonic/api.dart';
import 'package:segue/subsonic/models.dart';

import 'fakes.dart';

final hubBin = Platform.environment['SEGUE_HUB_BIN'] ?? '../hub/segue-hub';

const songs = [
  Song(id: '5QFKvMsJrd57QE2Le2dKKo', title: 'Dream On', artist: 'Aerosmith', duration: Duration(seconds: 268)),
  Song(id: '7N42dgm5tFLK9N8MT7fHC7', title: 'Other', duration: Duration(seconds: 200)),
];

late Process hub;
late Uri hubUrl;
var users = 0;

/// One app: a fake engine, the player, the hub client and the Connect controller.
class App {
  App(String user, this.name)
    : engine = FakeEngine(),
      client = SegueClient(
        url: hubUrl,
        auth: Auth.subsonic(username: user, token: '-', salt: '-'),
        device: DeviceInfo(
          id: name,
          name: name,
          client: 'test',
          api: Api.subsonic,
          roles: Role.values,
          capabilities: CommandAction.values,
        ),
      ) {
    player = PlayerController(
      engine,
      SubsonicApi(Uri.parse('https://music.test'), SubsonicCredentials(username: user, token: '-', salt: '-')),
    );
    connect = ConnectController(player: player, client: client);
  }

  final String name;
  final FakeEngine engine;
  final SegueClient client;
  late final PlayerController player;
  late final ConnectController connect;

  Future<App> start() async {
    await client.connect();
    addTearDown(client.close);
    return this;
  }
}

Future<void> until(bool Function() condition, String what) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  setUpAll(() async {
    hub = await Process.start(hubBin, [], environment: {'SEGUE_AUTH': 'none', 'SEGUE_LISTEN': '127.0.0.1:0'});
    final listening = Completer<Uri>();
    hub.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      final match = RegExp(r'msg="hub listening" url=http://(\S+)').firstMatch(line);
      if (match != null && !listening.isCompleted) listening.complete(Uri.parse('ws://${match[1]}/v1/ws'));
    });
    unawaited(hub.stderr.drain<void>());
    hubUrl = await listening.future.timeout(const Duration(seconds: 10));
  });
  tearDownAll(() async {
    hub.kill();
    await hub.exitCode;
  });

  String newUser() => 'user${++users}';

  test('a refused hello is a final HubClosed', () async {
    final client = SegueClient(
      url: hubUrl,
      auth: Auth.subsonic(username: newUser(), token: '-', salt: '-'),
      device: const DeviceInfo(id: 'x', name: '', client: 'test', api: Api.subsonic, roles: [], capabilities: []),
    );
    await expectLater(
      client.connect(),
      throwsA(
        isA<HubClosed>().having((e) => e.code, 'code', CloseCode.badHello).having((e) => e.isFinal, 'isFinal', true),
      ),
    );
  });

  test('a copy kicked out by another with the same device id stays out', () async {
    final user = newUser();
    final first = App(user, 'laptop');
    unawaited(first.client.start());
    addTearDown(first.client.close);
    await until(() => first.client.status == HubStatus.connected, 'the first copy');
    final second = await App(user, 'laptop').start();
    await until(() => first.client.status == HubStatus.rejected, 'the first copy to give up');
    expect(first.client.lastClose?.code, CloseCode.replaced);
    await Future<void>.delayed(const Duration(milliseconds: 1500)); // longer than the backoff
    expect(second.client.status, HubStatus.connected);
  });

  test('sees what another device plays, on the hub clock', () async {
    final user = newUser();
    final laptop = await App(user, 'laptop').start();
    final phone = await App(user, 'phone').start();
    await laptop.player.playQueue(songs, position: const Duration(seconds: 10));
    await until(() => phone.client.devices['laptop']?.state?.current != null, 'the laptop state');
    expect(phone.client.devices['laptop']!.state!.current!.title, 'Dream On');
    expect(phone.client.positionMs('laptop'), greaterThanOrEqualTo(10000));
  });

  test('an app with nothing playing shows, and controls, what plays on another device', () async {
    final user = newUser();
    final laptop = await App(user, 'laptop').start();
    final phone = await App(user, 'phone').start();
    await laptop.player.playQueue(songs);
    await until(() => phone.connect.nowPlaying?.device == 'laptop', 'the phone to follow the laptop');
    expect(phone.connect.nowPlaying?.title, 'Dream On');
    expect(phone.connect.nowPlaying?.playing, isTrue);
    expect(phone.connect.playingId, 'laptop');
    expect((await phone.connect.toggle()).ok, isTrue);
    expect(laptop.player.playing, isFalse);
    await until(() => phone.connect.nowPlaying?.playing == false, 'the phone to see the pause');
    expect(phone.connect.nowPlaying?.device, 'laptop', reason: 'a paused device stays on the bar');
  });

  test('when another device starts playing, every app follows it', () async {
    final user = newUser();
    final laptop = await App(user, 'laptop').start();
    final phone = await App(user, 'phone').start();
    await phone.player.playQueue(songs);
    await until(() => laptop.connect.nowPlaying?.device == 'phone', 'the laptop to follow the phone');
    await phone.player.toggle();
    await laptop.player.playQueue(songs, index: 1);
    expect(laptop.connect.nowPlaying?.device, isNull, reason: 'the laptop plays itself');
    await until(() => phone.connect.nowPlaying?.device == 'laptop', 'the phone to follow the laptop');
    expect(phone.connect.nowPlaying?.title, 'Other');
  });

  test('reopening the app brings back the last playback, paused where it was', () async {
    final user = newUser();
    final laptop = await App(user, 'laptop').start();
    await laptop.player.playQueue(songs, index: 1, position: const Duration(seconds: 30));
    await Future<void>.delayed(const Duration(milliseconds: 100)); // the report reaches the hub
    await laptop.client.close();
    final reopened = await App(user, 'laptop').start();
    await until(() => reopened.player.queue.isNotEmpty, 'the queue to come back');
    expect(reopened.player.index, 1);
    expect(reopened.player.playing, isFalse);
    expect(reopened.player.position.inMilliseconds, inInclusiveRange(30000, 31000));
    expect(reopened.connect.nowPlaying?.title, 'Other');
    expect(reopened.connect.nowPlaying?.device, isNull);
  });

  test('another device opening after the last one closed continues it there', () async {
    final user = newUser();
    final laptop = await App(user, 'laptop').start();
    await laptop.player.playQueue(songs);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await laptop.client.close();
    final phone = await App(user, 'phone').start();
    await until(() => phone.player.queue.isNotEmpty, 'the queue on the phone');
    expect(phone.player.current?.title, 'Dream On');
    expect(phone.player.playing, isFalse);
  });

  test('an app opened after another one that just opened shows the music on its own', () async {
    final user = newUser();
    final laptop = await App(user, 'laptop').start();
    await laptop.player.playQueue(songs);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await laptop.client.close();
    // The laptop opens again and loads it, with nobody pressing anything; then the phone opens.
    final again = await App(user, 'laptop').start();
    await until(() => again.player.queue.isNotEmpty, 'the music on the laptop');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final phone = await App(user, 'phone').start();
    await until(() => phone.player.queue.isNotEmpty, 'the music on the phone');
    expect(phone.connect.nowPlaying?.device, isNull);
    expect(again.connect.nowPlaying?.device, isNull);
  });

  test('opening while the last device is on and paused shows that device', () async {
    final user = newUser();
    final tv = await App(user, 'tv').start();
    await tv.player.playQueue(songs);
    await tv.player.toggle();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final phone = await App(user, 'phone').start();
    await until(() => phone.connect.nowPlaying?.device == 'tv', 'the phone to show the TV');
    expect(phone.connect.nowPlaying?.playing, isFalse);
    expect(phone.player.queue, isEmpty);
  });

  test('apps opened after the last one closed, with nothing played, each show it on their own', () async {
    final user = newUser();
    final laptop = await App(user, 'laptop').start();
    await laptop.player.playQueue(songs);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await laptop.client.close(); // closed while playing
    final desktop = await App(user, 'desktop').start();
    await until(() => desktop.player.queue.isNotEmpty, 'the queue on the desktop');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final again = await App(user, 'laptop').start();
    await until(() => again.player.queue.isNotEmpty, 'the queue on the laptop');
    expect(again.player.playing, isFalse);
    expect(again.connect.nowPlaying?.device, isNull);
    // The desktop doesn't follow the laptop that came back: it was playing when it closed, not now.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(desktop.connect.activeId, isNull);
    expect(desktop.connect.nowPlaying?.device, isNull);
  });

  test('when the device it follows closes, its music stays here, paused where it got to', () async {
    final user = newUser();
    final laptop = await App(user, 'laptop').start();
    final phone = await App(user, 'phone').start();
    await laptop.player.playQueue(songs, index: 1, position: const Duration(seconds: 30));
    await until(() => phone.connect.nowPlaying?.device == 'laptop', 'the phone to follow the laptop');
    await laptop.client.close();
    await until(() => phone.player.queue.isNotEmpty, 'the music on the phone');
    expect(phone.connect.activeId, isNull);
    expect(phone.connect.devices, isEmpty);
    expect(phone.connect.nowPlaying?.device, isNull);
    expect(phone.connect.nowPlaying?.title, 'Other');
    expect(phone.player.playing, isFalse);
    expect(phone.player.position.inMilliseconds, greaterThanOrEqualTo(30000));
    // Keeping it isn't playing it: the laptop, opened again, still has the last playback, and
    // shows it on its own, as the phone does.
    final again = await App(user, 'laptop').start();
    await until(() => again.player.queue.isNotEmpty, 'the music back on the laptop');
    expect(again.connect.nowPlaying?.device, isNull);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(phone.connect.nowPlaying?.device, isNull);
  });

  test('repeat and shuffle go to the device it controls, and show from its state', () async {
    final user = newUser();
    final laptop = await App(user, 'laptop').start();
    final phone = await App(user, 'phone').start();
    await laptop.player.playQueue(songs);
    await until(() => phone.connect.nowPlaying?.device == 'laptop', 'the phone to follow the laptop');
    expect(phone.connect.nowPlaying?.canRepeat, isTrue);
    expect(phone.connect.nowPlaying?.canShuffle, isTrue);
    expect((await phone.connect.setRepeat(Repeat.all)).ok, isTrue);
    expect(laptop.player.repeat, Repeat.all);
    await until(() => phone.connect.nowPlaying?.repeat == Repeat.all, 'the phone to show the repeat');
    expect((await phone.connect.setShuffle(true)).ok, isTrue);
    expect(laptop.player.shuffle, isTrue);
    await until(() => phone.connect.nowPlaying?.shuffle ?? false, 'the phone to show the shuffle');
    expect(phone.player.repeat, Repeat.off, reason: 'not the phone\'s own player');
  });

  test('the queue shown is that of the device it controls, and a tap on a track plays it there', () async {
    final user = newUser();
    final laptop = await App(user, 'laptop').start();
    final phone = await App(user, 'phone').start();
    await laptop.player.playQueue(songs);
    await until(() => phone.connect.nowPlaying?.device == 'laptop', 'the phone to follow the laptop');
    expect(phone.connect.queue.tracks.map((track) => track.title), ['Dream On', 'Other']);
    expect(phone.connect.queue.index, 0);
    expect(phone.connect.nowPlaying?.canJump, isTrue);
    await laptop.player.pause();
    expect((await phone.connect.jump(1)).ok, isTrue);
    expect(laptop.player.current?.title, 'Other');
    expect(laptop.player.playing, isTrue);
    await until(() => phone.connect.queue.index == 1, 'the phone to see the new track');
    expect(phone.player.queue, isEmpty, reason: 'not the phone\'s own player');
  });

  test('starting to play on one device stops the others: no other is left paused with the music', () async {
    final user = newUser();
    final laptop = await App(user, 'laptop').start();
    final phone = await App(user, 'phone').start();
    await laptop.player.playQueue(songs);
    await until(() => phone.connect.playingId == 'laptop', 'the phone to see the laptop playing');
    await phone.player.playQueue(songs, index: 1);
    await until(() => laptop.player.queue.isEmpty, 'the laptop to stop');
    expect(laptop.player.status, PlaybackStatus.stopped);
    await until(
      () => phone.client.devices['laptop']?.state?.status == PlaybackStatus.stopped,
      'the phone to see the laptop stopped, not paused',
    );
    expect(phone.player.playing, isTrue);
    await until(() => laptop.connect.nowPlaying?.device == 'phone', 'the laptop to follow the phone');
  });

  test('the system controls of an app that follows another device command that device', () async {
    final user = newUser();
    final laptop = await App(user, 'laptop').start();
    final phone = await App(user, 'phone').start();
    final controls = MediaControls()..attach(phone.connect, null);
    addTearDown(() => controls.attach(null, null));
    await laptop.player.playQueue(songs);
    await until(() => controls.mediaItem.value?.artist == 'Aerosmith (em laptop)', 'the phone to show the laptop');
    expect(controls.mediaItem.value?.title, 'Dream On');
    await controls.pause();
    expect(laptop.player.playing, isFalse);
    await controls.play();
    expect(laptop.player.playing, isTrue);
  });

  test('a device that follows another sees its track change', () async {
    final user = newUser();
    final laptop = await App(user, 'laptop').start();
    final phone = await App(user, 'phone').start();
    await laptop.player.playQueue(songs);
    await until(() => phone.connect.nowPlaying?.title == 'Dream On', 'the phone to show the first track');
    await laptop.player.next();
    await until(() => phone.connect.nowPlaying?.title == 'Other', 'the phone to show the next track');
    expect(phone.connect.nowPlaying!.position.inSeconds, lessThan(2));
  });

  test('the Spotify flow: control another device, then move the music here', () async {
    final user = newUser();
    final laptop = await App(user, 'laptop').start();
    final phone = await App(user, 'phone').start();
    await laptop.player.playQueue(songs, index: 1, position: const Duration(seconds: 30));
    await until(() => phone.client.devices['laptop']?.state?.current != null, 'the laptop queue');

    // Pick the laptop: nothing plays on the phone, so nothing moves; the phone now controls it.
    expect((await phone.connect.switchTo('laptop')).ok, isTrue);
    expect(phone.connect.nowPlaying?.device, 'laptop');
    expect(phone.connect.nowPlaying?.title, 'Other');
    expect((await phone.connect.toggle()).ok, isTrue);
    expect(laptop.player.playing, isFalse);
    expect((await phone.connect.toggle()).ok, isTrue);
    expect(laptop.player.playing, isTrue);
    expect((await phone.connect.next()).error, 'no such track', reason: "the laptop's own error comes back");

    // Pick this phone again: the music moves here, at the laptop's position, and the laptop stops:
    // idle, not paused with music that now plays here.
    expect((await phone.connect.switchTo(null)).ok, isTrue);
    expect(phone.player.queue.map((song) => song.id), songs.map((song) => song.id));
    expect(phone.player.index, 1);
    expect(phone.player.playing, isTrue);
    expect(phone.player.position.inMilliseconds, greaterThanOrEqualTo(30000));
    expect(laptop.player.queue, isEmpty);
    expect(laptop.player.status, PlaybackStatus.stopped);
    await until(
      () => phone.client.devices['laptop']?.state?.status == PlaybackStatus.stopped,
      'the phone to see the laptop stopped, not paused',
    );
    expect(phone.connect.nowPlaying?.device, isNull);
  });

  test('playing an album while another device is picked plays it there', () async {
    final user = newUser();
    final laptop = await App(user, 'laptop').start();
    final phone = await App(user, 'phone').start();
    await until(() => phone.client.devices.containsKey('laptop'), 'the laptop');
    await phone.connect.switchTo('laptop');
    expect((await phone.connect.playSongs(songs, 0)).ok, isTrue);
    expect(laptop.player.current?.title, 'Dream On');
    expect(laptop.player.playing, isTrue);
    expect(phone.player.queue, isEmpty);
  });

  test('a closed app leaves the list of devices to play on', () async {
    final user = newUser();
    final laptop = await App(user, 'laptop').start();
    final phone = await App(user, 'phone').start();
    await until(() => phone.connect.devices.any((d) => d.id == 'laptop'), 'the laptop');
    await laptop.client.close();
    await until(() => phone.client.devices['laptop']?.online == false, 'the laptop to go offline');
    expect(phone.connect.devices, isEmpty);
  });
}
