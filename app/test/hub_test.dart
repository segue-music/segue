// The app's Segue client and ConnectController against the real (Go) hub. Needs the hub binary
// (go build -o segue-hub ./cmd/segue-hub in ../hub, or its path in SEGUE_HUB_BIN).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:segue/connect/connect.dart';
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

  test('sees what another device plays, on the hub clock', () async {
    final user = newUser();
    final laptop = await App(user, 'laptop').start();
    final phone = await App(user, 'phone').start();
    await laptop.player.playQueue(songs, position: const Duration(seconds: 10));
    await until(() => phone.client.devices['laptop']?.state?.current != null, 'the laptop state');
    expect(phone.client.devices['laptop']!.state!.current!.title, 'Dream On');
    expect(phone.client.positionMs('laptop'), greaterThanOrEqualTo(10000));
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

    // Pick this phone again: the music moves here, at the laptop's position, and the laptop pauses.
    expect((await phone.connect.switchTo(null)).ok, isTrue);
    expect(phone.player.queue.map((song) => song.id), songs.map((song) => song.id));
    expect(phone.player.index, 1);
    expect(phone.player.playing, isTrue);
    expect(phone.player.position.inMilliseconds, greaterThanOrEqualTo(30000));
    expect(laptop.player.playing, isFalse);
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

  test('continues here what a closed app was playing', () async {
    final user = newUser();
    final laptop = await App(user, 'laptop').start();
    final phone = await App(user, 'phone').start();
    await laptop.player.playQueue(songs);
    await until(() => phone.client.devices['laptop']?.state?.current != null, 'the laptop queue');
    await laptop.client.close();
    await until(() => phone.client.devices['laptop']?.online == false, 'the laptop to go offline');
    expect((await phone.connect.continueFrom('laptop')).ok, isTrue);
    expect(phone.player.current?.title, 'Dream On');
  });
}
