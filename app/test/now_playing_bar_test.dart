import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:segue/connect/connect.dart';
import 'package:segue/player/player.dart';
import 'package:segue/segue/client.dart';
import 'package:segue/segue/protocol.dart';
import 'package:segue/server/models.dart';
import 'package:segue/services.dart';
import 'package:segue/session.dart';
import 'package:segue/subsonic/api.dart';
import 'package:segue/ui/now_playing_bar.dart';

import 'fakes.dart';

void main() {
  testWidgets('on a phone-sized screen, the bar shows what plays on another device, and where', (tester) async {
    const credentials = SubsonicCredentials(username: 'a', token: 't', salt: 's');
    final api = SubsonicApi(
      Uri.parse('https://music.test'),
      credentials,
      client: MockClient((_) async => http.Response('', 404)),
    );
    final player = PlayerController(FakeEngine(), api);
    final client = SegueClient(
      url: Uri.parse('ws://unused'),
      auth: const Auth.subsonic(username: 'a', token: 't', salt: 's'),
      device: const DeviceInfo(id: 'me', name: 'me', client: 'test', api: Api.subsonic, roles: [], capabilities: []),
    );
    client.devices['tv'] = Device(
      info: const DeviceInfo(
        id: 'tv',
        name: 'Sala de estar',
        client: 'test',
        api: Api.subsonic,
        roles: [Role.player],
        capabilities: [],
      ),
      online: true,
      state: StampedState(
        status: PlaybackStatus.playing,
        positionMs: 61000,
        at: DateTime.now().millisecondsSinceEpoch,
        index: 0,
        queue: const [QueueItem(id: 's1', title: 'Dream On', artist: 'Aerosmith', durationMs: 268000)],
      ),
    );
    final connect = ConnectController(player: player, client: client);
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    client.notifyListeners(); // as when the TV's state arrives
    final services = Services(
      Session(server: Uri.parse('https://music.test'), credentials: credentials, deviceId: 'me', deviceName: 'me'),
      api,
      player,
      connect,
    );

    // The screen itself, not just the surface: the bar picks what fits from MediaQuery.
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: ServicesScope(
          services: services,
          child: const Scaffold(bottomNavigationBar: NowPlayingBar()),
        ),
      ),
    );
    expect(find.text('Dream On'), findsOneWidget);
    expect(find.text('Aerosmith'), findsOneWidget);
    expect(find.text('Tocando em Sala de estar'), findsOneWidget);
    expect(find.text('1:01'), findsOneWidget);
    await tester.pumpWidget(const SizedBox()); // stops the bar's timer
  });

  testWidgets('the slider jumps to where it is tapped, or to where a drag lets go', (tester) async {
    const credentials = SubsonicCredentials(username: 'a', token: 't', salt: 's');
    final api = SubsonicApi(
      Uri.parse('https://music.test'),
      credentials,
      client: MockClient((_) async => http.Response('', 404)),
    );
    final player = PlayerController(FakeEngine(), api);
    await player.playQueue(const [
      Song(id: 's1', title: 'Dream On', artist: 'Aerosmith', duration: Duration(seconds: 268)),
    ], play: false);
    final services = Services(
      Session(server: Uri.parse('https://music.test'), credentials: credentials, deviceId: 'me', deviceName: 'me'),
      api,
      player,
      ConnectController(player: player),
    );
    // The screen itself, not just the surface: the bar picks what fits from MediaQuery.
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: ServicesScope(
          services: services,
          child: const Scaffold(bottomNavigationBar: NowPlayingBar()),
        ),
      ),
    );

    await tester.tap(find.byType(Slider)); // its middle
    await tester.pump();
    expect(player.position.inSeconds, closeTo(134, 3));
    expect(find.text(formatDuration(player.position)), findsOneWidget);

    // While dragging, the time shows where it would go, and nothing moves until it lets go.
    final slider = tester.getRect(find.byType(Slider));
    final drag = await tester.startGesture(Offset(slider.left + 14 + 4, slider.center.dy));
    await tester.pump();
    await drag.moveTo(Offset(slider.left + 14 + (slider.width - 28) * 0.75, slider.center.dy));
    await tester.pump();
    expect(player.position.inSeconds, closeTo(134, 3));
    expect(find.text('3:21'), findsOneWidget);
    await drag.up();
    await tester.pump();
    expect(player.position.inSeconds, closeTo(201, 3));
    await tester.pumpWidget(const SizedBox()); // stops the bar's timers
  });

  testWidgets('shuffle and repeat buttons, on a wide screen: shuffle toggles, repeat goes off, list, track', (
    tester,
  ) async {
    const credentials = SubsonicCredentials(username: 'a', token: 't', salt: 's');
    final api = SubsonicApi(
      Uri.parse('https://music.test'),
      credentials,
      client: MockClient((_) async => http.Response('', 404)),
    );
    final player = PlayerController(FakeEngine(), api);
    await player.playQueue(const [
      Song(id: 's1', title: 'Dream On', duration: Duration(seconds: 268)),
      Song(id: 's2', title: 'Other', duration: Duration(seconds: 200)),
    ], play: false);
    final services = Services(
      Session(server: Uri.parse('https://music.test'), credentials: credentials, deviceId: 'me', deviceName: 'me'),
      api,
      player,
      ConnectController(player: player),
    );

    Future<void> pumpAt(Size size) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(
        MaterialApp(
          home: ServicesScope(
            services: services,
            child: const Scaffold(bottomNavigationBar: NowPlayingBar()),
          ),
        ),
      );
    }

    addTearDown(tester.view.reset);
    await pumpAt(const Size(1000, 600));
    await tester.tap(find.byTooltip('Ativar aleatório'));
    await tester.pump();
    expect(player.shuffle, isTrue);
    expect(find.byTooltip('Desativar aleatório'), findsOneWidget);

    await tester.tap(find.byTooltip('Repetir a lista'));
    await tester.pump();
    expect(player.repeat, Repeat.all);
    await tester.tap(find.byTooltip('Repetir a faixa'));
    await tester.pump();
    expect(player.repeat, Repeat.one);
    await tester.tap(find.byTooltip('Não repetir'));
    await tester.pump();
    expect(player.repeat, Repeat.off);

    // No room for them in a phone-sized bar.
    await pumpAt(const Size(360, 640));
    expect(find.byTooltip('Ativar aleatório'), findsNothing);
    expect(find.byTooltip('Repetir a lista'), findsNothing);
    await tester.pumpWidget(const SizedBox()); // stops the bar's timers
  });
}
