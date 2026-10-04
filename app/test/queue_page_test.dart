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
import 'package:segue/ui/queue_page.dart';
import 'package:segue/ui/shortcuts.dart';

import 'fakes.dart';

const credentials = SubsonicCredentials(username: 'a', token: 't', salt: 's');

const songs = [
  Song(id: 's1', title: 'One', artist: 'Aerosmith', duration: Duration(seconds: 180)),
  Song(id: 's2', title: 'Two', artist: 'Aerosmith', duration: Duration(seconds: 200)),
  Song(id: 's3', title: 'Three', artist: 'Aerosmith', duration: Duration(seconds: 220)),
  Song(id: 's4', title: 'Four', artist: 'Aerosmith', duration: Duration(seconds: 240)),
];

/// The player bar, under the navigator as in the app, with [songs] playing from the second one, or,
/// with [client], what its devices play. [television] as on a TV.
Future<PlayerController> pumpBar(
  WidgetTester tester, {
  SegueClient? client,
  Size size = const Size(360, 640),
  bool television = false,
}) async {
  final api = SubsonicApi(
    Uri.parse('https://music.test'),
    credentials,
    client: MockClient((_) async => http.Response('', 404)),
  );
  final player = PlayerController(FakeEngine(), api);
  if (client == null) await player.playQueue(songs, index: 1);
  final connect = ConnectController(player: player, client: client);
  // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
  client?.notifyListeners(); // as when another device's state arrives
  final services = Services(
    Session(server: Uri.parse('https://music.test'), credentials: credentials, deviceId: 'me', deviceName: 'me'),
    api,
    player,
    connect,
  );
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => ServicesScope(
        services: services,
        child: DirectionalNavigation(enabled: television, child: child!),
      ),
      home: const Scaffold(body: SizedBox.expand(), bottomNavigationBar: NowPlayingBar()),
    ),
  );
  return player;
}

/// Opens the full-screen player, and the queue from it.
Future<void> openQueue(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Abrir o player'));
  await tester.pumpAndSettle();
  await tester.tap(find.descendant(of: find.byType(PlayerPage), matching: find.byTooltip('Fila')));
  await tester.pumpAndSettle();
}

Finder inQueue(Finder finder) => find.descendant(of: find.byType(QueuePage), matching: finder);

ListTile tile(WidgetTester tester, String title) =>
    tester.widget<ListTile>(find.ancestor(of: inQueue(find.text(title)), matching: find.byType(ListTile)));

SegueClient clientWithTv({required List<CommandAction> capabilities}) {
  final client = SegueClient(
    url: Uri.parse('ws://unused'),
    auth: const Auth.subsonic(username: 'a', token: 't', salt: 's'),
    device: const DeviceInfo(id: 'me', name: 'me', client: 'test', api: Api.subsonic, roles: [], capabilities: []),
  );
  client.devices['tv'] = Device(
    info: DeviceInfo(
      id: 'tv',
      name: 'Sala de estar',
      client: 'test',
      api: Api.subsonic,
      roles: const [Role.player],
      capabilities: capabilities,
    ),
    online: true,
    state: StampedState(
      status: PlaybackStatus.playing,
      positionMs: 1000,
      at: DateTime.now().millisecondsSinceEpoch,
      index: 1,
      queue: const [
        QueueItem(id: 's1', title: 'Dream On', artist: 'Aerosmith', durationMs: 268000),
        QueueItem(id: 's2', title: 'Walk This Way', artist: 'Aerosmith', durationMs: 220000),
        QueueItem(title: 'Untranslatable'),
      ],
    ),
  );
  return client;
}

void main() {
  testWidgets('the full-screen player opens the queue: the current track on top, the next ones under it', (
    tester,
  ) async {
    await pumpBar(tester);
    await openQueue(tester);
    expect(find.byType(QueuePage), findsOneWidget);
    expect(inQueue(find.text('Fila')), findsOneWidget);
    for (final title in ['Two', 'Three', 'Four']) {
      expect(inQueue(find.text(title)), findsOneWidget, reason: title);
    }
    expect(tile(tester, 'Two').selected, isTrue, reason: 'the current track stands out');
    expect(tile(tester, 'Three').selected, isFalse);
    expect(inQueue(find.byIcon(Icons.graphic_eq)), findsOneWidget, reason: 'it plays');
    expect(inQueue(find.text('3:20')), findsOneWidget, reason: 'how long it lasts');
    final top = tester.getTopLeft(find.byType(CustomScrollView)).dy;
    expect(tester.getTopLeft(find.ancestor(of: inQueue(find.text('Two')), matching: find.byType(ListTile))).dy, top);

    // What played before is above it.
    expect(inQueue(find.text('One')), findsNothing);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 300));
    await tester.pumpAndSettle();
    expect(inQueue(find.text('One')), findsOneWidget);
    expect(tile(tester, 'One').selected, isFalse);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(QueuePage), findsNothing);
    expect(find.byType(PlayerPage), findsOneWidget);
    await tester.pumpWidget(const SizedBox()); // stops the timers
  });

  testWidgets('a tap on a track in the queue plays it, from its start', (tester) async {
    final player = await pumpBar(tester);
    await player.pause();
    await openQueue(tester);
    await tester.tap(inQueue(find.text('Four')));
    await tester.pump();
    expect(player.current?.title, 'Four');
    expect(player.playing, isTrue);
    expect(player.position.inSeconds, 0);
    expect(tile(tester, 'Four').selected, isTrue);
    expect(tile(tester, 'Two').selected, isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the queue is that of the device the app controls, wherever it plays', (tester) async {
    final player = await pumpBar(tester, client: clientWithTv(capabilities: CommandAction.values));
    await openQueue(tester);
    expect(inQueue(find.text('Fila em Sala de estar')), findsOneWidget);
    expect(inQueue(find.text('Walk This Way')), findsOneWidget);
    expect(inQueue(find.text('Untranslatable')), findsOneWidget, reason: 'shown, though it can\'t play here');
    expect(tile(tester, 'Walk This Way').selected, isTrue);
    expect(tile(tester, 'Untranslatable').onTap, isNotNull);
    expect(player.queue, isEmpty, reason: 'not this device\'s');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('on a device that takes no jump, the queue shows but its tracks do nothing', (tester) async {
    await pumpBar(
      tester,
      client: clientWithTv(capabilities: [...CommandAction.values.where((a) => a != CommandAction.jump)]),
    );
    await openQueue(tester);
    expect(inQueue(find.text('Walk This Way')), findsOneWidget);
    expect(tile(tester, 'Untranslatable').onTap, isNull);
    expect(tile(tester, 'Walk This Way').onTap, isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('on a TV, the current track has the focus when the queue opens', (tester) async {
    await pumpBar(tester, size: const Size(1000, 600), television: true);
    await openQueue(tester);
    expect(Focus.of(tester.element(inQueue(find.text('Two')))).hasPrimaryFocus, isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a wide player bar opens the queue too; a phone-sized one has no room for it', (tester) async {
    await pumpBar(tester, size: const Size(1000, 600));
    await tester.tap(find.byTooltip('Fila'));
    await tester.pumpAndSettle();
    expect(find.byType(QueuePage), findsOneWidget);
    await tester.pumpWidget(const SizedBox());

    await pumpBar(tester);
    expect(find.byTooltip('Fila'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
