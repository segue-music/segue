import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'package:segue/ui/album_page.dart';
import 'package:segue/ui/artist_page.dart';
import 'package:segue/ui/now_playing_bar.dart';
import 'package:segue/ui/player_page.dart';

import 'fakes.dart';

const credentials = SubsonicCredentials(username: 'a', token: 't', salt: 's');

http.Response subsonic(Map<String, Object?> body) => http.Response(
  jsonEncode({
    'subsonic-response': {'status': 'ok', ...body},
  }),
  200,
  headers: {'content-type': 'application/json'},
);

/// A media server that knows two songs, with their albums and artists: Sweet Emotion (s1), by
/// Aerosmith, and Walk This Way (s2), by Run-DMC with Aerosmith.
http.Response library(http.Request request) {
  final path = request.url.path;
  final id = request.url.queryParameters['id'];
  const songs = {
    's1': {
      'id': 's1',
      'title': 'Sweet Emotion',
      'artist': 'Aerosmith',
      'album': 'Toys in the Attic',
      'albumId': 'a1',
      'artistId': 'ar1',
    },
    's2': {
      'id': 's2',
      'title': 'Walk This Way',
      'artist': 'Run-DMC, Aerosmith',
      'album': 'Raising Hell',
      'albumId': 'a2',
      'artistId': 'ar2',
    },
  };
  final albums = {
    'a1': {
      'id': 'a1',
      'name': 'Toys in the Attic',
      'artist': 'Aerosmith',
      'song': [?songs['s1']],
    },
    'a2': {
      'id': 'a2',
      'name': 'Raising Hell',
      'artist': 'Run-DMC',
      'song': [?songs['s2']],
    },
  };
  final artists = {
    'ar1': {
      'id': 'ar1',
      'name': 'Aerosmith',
      'album': [
        {'id': 'a1', 'name': 'Toys in the Attic', 'year': 1975},
        {'id': 'a3', 'name': 'Get Your Wings', 'year': 1974},
      ],
    },
    'ar2': {
      'id': 'ar2',
      'name': 'Run-DMC',
      'album': [
        {'id': 'a2', 'name': 'Raising Hell', 'year': 1986},
      ],
    },
  };
  final found = switch (path.split('/').last) {
    'getSong.view' => songs[id] == null ? null : {'song': songs[id]},
    'getAlbum.view' => albums[id] == null ? null : {'album': albums[id]},
    'getArtist.view' => artists[id] == null ? null : {'artist': artists[id]},
    _ => null,
  };
  return found == null ? http.Response('', 404) : subsonic(found);
}

/// A hub client that sees the device tv play [song].
SegueClient tvPlaying(QueueItem song) {
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
      queue: [song],
    ),
  );
  return client;
}

/// The player bar, under the navigator as in the app, on a screen of [size] (a phone's by default),
/// playing Sweet Emotion here. [client] adds a hub, and the bar then shows what it says; [server]
/// answers for the media server, which by default knows nothing.
Future<PlayerController> pumpBar(
  WidgetTester tester, {
  SegueClient? client,
  http.Response Function(http.Request request)? server,
  Size size = const Size(360, 640),
}) async {
  final api = SubsonicApi(
    Uri.parse('https://music.test'),
    credentials,
    client: MockClient((request) async => server?.call(request) ?? http.Response('', 404)),
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
  tester.view.physicalSize = size;
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
    await pumpBar(
      tester,
      client: tvPlaying(const QueueItem(id: 's1', title: 'Dream On', artist: 'Aerosmith', album: 'Aerosmith')),
    );
    await openPlayer(tester);
    expect(onPage(find.text('Tocando em Sala de estar')), findsOneWidget);
    expect(onPage(find.text('Dream On')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the title opens the album, and the artist their page, in place of the player', (tester) async {
    await pumpBar(tester, server: library);
    await openPlayer(tester);
    await tester.tap(onPage(find.text('Sweet Emotion')));
    await tester.pumpAndSettle();
    expect(find.byType(PlayerPage), findsNothing);
    expect(find.byType(AlbumPage), findsOneWidget);
    expect(find.widgetWithText(AppBar, 'Toys in the Attic'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(AlbumPage), findsNothing, reason: 'back goes where the player was opened from');
    expect(find.byType(PlayerPage), findsNothing);

    await openPlayer(tester);
    await tester.tap(onPage(find.text('Aerosmith')));
    await tester.pumpAndSettle();
    expect(find.byType(PlayerPage), findsNothing);
    expect(find.byType(ArtistPage), findsOneWidget);
    expect(find.text('Get Your Wings'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the album\'s name opens it too', (tester) async {
    await pumpBar(tester, server: library);
    await openPlayer(tester);
    await tester.tap(onPage(find.text('Toys in the Attic')));
    await tester.pumpAndSettle();
    expect(find.byType(PlayerPage), findsNothing);
    expect(find.byType(AlbumPage), findsOneWidget);
    expect(find.widgetWithText(AppBar, 'Toys in the Attic'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('another device\'s song links too, and the artist page is named after the artist it opened', (
    tester,
  ) async {
    await pumpBar(
      tester,
      client: tvPlaying(const QueueItem(id: 's2', title: 'Walk This Way', artist: 'Run-DMC, Aerosmith')),
      server: library,
    );
    await openPlayer(tester);
    await tester.tap(onPage(find.text('Run-DMC, Aerosmith')));
    await tester.pumpAndSettle();
    expect(find.byType(ArtistPage), findsOneWidget);
    expect(find.widgetWithText(AppBar, 'Run-DMC'), findsOneWidget);
    expect(find.text('Raising Hell'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a song the server can\'t find opens nothing, and says so', (tester) async {
    await pumpBar(tester);
    await openPlayer(tester);
    await tester.tap(onPage(find.text('Sweet Emotion')));
    await tester.pumpAndSettle();
    expect(find.byType(PlayerPage), findsOneWidget);
    expect(find.byType(AlbumPage), findsNothing);
    expect(find.textContaining('Não consegui abrir o álbum'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a song the hub couldn\'t give in this device\'s API links nowhere', (tester) async {
    final asked = <http.Request>[];
    await pumpBar(
      tester,
      client: tvPlaying(const QueueItem(title: 'Dream On', artist: 'Aerosmith')),
      server: (request) {
        asked.add(request);
        return library(request);
      },
    );
    await openPlayer(tester);
    await tester.tap(onPage(find.text('Dream On')), warnIfMissed: false);
    await tester.tap(onPage(find.text('Aerosmith')), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.byType(PlayerPage), findsOneWidget);
    expect(asked.where((request) => request.url.path.endsWith('getSong.view')), isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a wide bar links too: the title to the album, the artist to their page; the rest opens the player', (
    tester,
  ) async {
    await pumpBar(tester, server: library, size: const Size(1000, 600));
    await tester.tap(find.byTooltip('Abrir o álbum'));
    await tester.pumpAndSettle();
    expect(find.byType(AlbumPage), findsOneWidget);
    expect(find.widgetWithText(AppBar, 'Toys in the Attic'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Abrir o artista'));
    await tester.pumpAndSettle();
    expect(find.byType(ArtistPage), findsOneWidget);
    expect(find.text('Get Your Wings'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(ArtistPage), findsNothing);

    await openPlayer(tester);
    expect(find.byType(PlayerPage), findsOneWidget);
    expect(
      onPage(find.byTooltip('Abrir o álbum')),
      findsNWidgets(2),
      reason: 'the player\'s links say where they go: its title and its album\'s name open the album',
    );
    expect(onPage(find.byTooltip('Abrir o artista')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('on a phone, the whole song in the bar opens the player, its title and artist included', (tester) async {
    await pumpBar(tester, server: library);
    expect(find.byTooltip('Abrir o álbum'), findsNothing);
    expect(find.byTooltip('Abrir o artista'), findsNothing);
    await tester.tap(find.text('Aerosmith'));
    await tester.pumpAndSettle();
    expect(find.byType(PlayerPage), findsOneWidget);
    expect(find.byType(ArtistPage), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a link is underlined under the mouse', (tester) async {
    await pumpBar(tester, server: library, size: const Size(1000, 600));
    TextDecoration? decoration() => tester.widget<Text>(find.text('Aerosmith')).style?.decoration;

    expect(decoration(), isNot(TextDecoration.underline));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('Aerosmith')));
    await tester.pump();
    expect(decoration(), TextDecoration.underline);
    await mouse.moveTo(Offset.zero);
    await tester.pump();
    expect(decoration(), isNot(TextDecoration.underline));
    await tester.pumpWidget(const SizedBox());
  });
}
