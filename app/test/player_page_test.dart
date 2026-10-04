import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:segue/connect/connect.dart';
import 'package:segue/player/player.dart';
import 'package:segue/segue/client.dart';
import 'package:segue/segue/protocol.dart';
import 'package:segue/services.dart';
import 'package:segue/session.dart';
import 'package:segue/subsonic/api.dart';
import 'package:segue/subsonic/models.dart';
import 'package:segue/ui/now_playing_bar.dart';
import 'package:segue/ui/player_page.dart';

import 'fakes.dart';

const credentials = SubsonicCredentials(username: 'a', token: 't', salt: 's');

/// The player bar, under the navigator as in the app, on a phone-sized screen. [client] adds a hub.
Future<PlayerController> pumpBar(WidgetTester tester, {SegueClient? client}) async {
  final api = SubsonicApi(
    Uri.parse('https://music.test'),
    credentials,
    client: MockClient((_) async => http.Response('', 404)),
  );
  final player = PlayerController(FakeEngine(), api);
  if (client == null) {
    await player.playQueue(const [
      Song(
        id: 's1',
        title: 'Sweet Emotion',
        artist: 'Aerosmith',
        album: 'Toys in the Attic',
        duration: Duration(seconds: 274),
      ),
    ], play: false);
  }
  final connect = ConnectController(player: player, client: client);
  // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
  client?.notifyListeners(); // as when another device's state arrives
  final services = Services(
    Session(server: Uri.parse('https://music.test'), credentials: credentials, deviceId: 'me', deviceName: 'me'),
    api,
    player,
    connect,
  );
  tester.view.physicalSize = const Size(360, 640);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => ServicesScope(services: services, child: child!),
      home: const Scaffold(body: SizedBox.expand(), bottomNavigationBar: NowPlayingBar()),
    ),
  );
  return player;
}

Future<void> openPlayer(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Abrir o player'));
  await tester.pumpAndSettle();
}

Finder onPage(Finder finder) => find.descendant(of: find.byType(PlayerPage), matching: finder);

void main() {
  testWidgets('the bar opens the full-screen player: the song, its times and every control, even on a phone', (
    tester,
  ) async {
    final player = await pumpBar(tester);
    expect(find.text('4:34'), findsOneWidget, reason: 'the bar shows how long the song is');
    await openPlayer(tester);
    expect(find.byType(PlayerPage), findsOneWidget);
    expect(onPage(find.text('Sweet Emotion')), findsOneWidget);
    expect(onPage(find.text('Aerosmith')), findsOneWidget);
    expect(onPage(find.text('Toys in the Attic')), findsOneWidget);
    expect(onPage(find.text('0:00')), findsOneWidget);
    expect(onPage(find.text('4:34')), findsOneWidget);
    for (final tooltip in ['Ativar aleatório', 'Anterior', 'Tocar', 'Próxima', 'Repetir a lista', 'Aparelhos']) {
      expect(onPage(find.byTooltip(tooltip)), findsOneWidget, reason: tooltip);
    }

    await tester.tap(onPage(find.byTooltip('Tocar')));
    await tester.pump();
    expect(player.playing, isTrue);
    expect(onPage(find.byTooltip('Pausar')), findsOneWidget);

    await tester.tap(onPage(find.byTooltip('Fechar')));
    await tester.pumpAndSettle();
    expect(find.byType(PlayerPage), findsNothing);
    await tester.pumpWidget(const SizedBox()); // stops the timers
  });

  testWidgets('Esc closes the full-screen player', (tester) async {
    await pumpBar(tester);
    await openPlayer(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(PlayerPage), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('its slider jumps to where it is tapped', (tester) async {
    final player = await pumpBar(tester);
    await openPlayer(tester);
    await tester.tap(onPage(find.byType(Slider)));
    await tester.pump();
    expect(player.position.inSeconds, closeTo(137, 3));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('it says where it plays, when that is another device', (tester) async {
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
        capabilities: CommandAction.values,
      ),
      online: true,
      state: StampedState(
        status: PlaybackStatus.playing,
        positionMs: 61000,
        at: DateTime.now().millisecondsSinceEpoch,
        index: 0,
        queue: const [QueueItem(id: 's1', title: 'Dream On', artist: 'Aerosmith', album: 'Aerosmith')],
      ),
    );
    await pumpBar(tester, client: client);
    await openPlayer(tester);
    expect(onPage(find.text('Tocando em Sala de estar')), findsOneWidget);
    expect(onPage(find.text('Dream On')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
