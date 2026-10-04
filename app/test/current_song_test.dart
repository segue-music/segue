import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
import 'package:segue/ui/album_page.dart';
import 'package:segue/ui/search_results.dart';

import 'fakes.dart';

http.Response subsonic(Map<String, Object?> body) => http.Response(
  jsonEncode({
    'subsonic-response': {'status': 'ok', ...body},
  }),
  200,
  headers: {'content-type': 'application/json'},
);

const credentials = SubsonicCredentials(username: 'a', token: 't', salt: 's');
const album = Album(id: 'a1', name: 'Aerosmith', artist: 'Aerosmith');
const songs = [
  Song(id: 's1', title: 'Make It', artist: 'Aerosmith', album: 'Aerosmith', duration: Duration(seconds: 222)),
  Song(id: 's2', title: 'Dream On', artist: 'Aerosmith', album: 'Aerosmith', duration: Duration(seconds: 268)),
];

/// The app's services over a server with one album, [album], of [songs], and with [client] when given.
Services fakeServices({SegueClient? client}) {
  final api = SubsonicApi(
    Uri.parse('https://music.test'),
    credentials,
    client: MockClient(
      (request) async => subsonic({
        'album': {
          'id': album.id,
          'name': album.name,
          'artist': album.artist,
          'song': [
            for (final song in songs)
              {
                'id': song.id,
                'title': song.title,
                'artist': song.artist,
                'album': song.album,
                'duration': song.duration!.inSeconds,
              },
          ],
        },
      }),
    ),
  );
  final player = PlayerController(FakeEngine(), api);
  return Services(
    Session(server: Uri.parse('https://music.test'), credentials: credentials, deviceId: 'me', deviceName: 'me'),
    api,
    player,
    ConnectController(player: player, client: client),
  );
}

Future<void> pump(WidgetTester tester, Services services, Widget page) async {
  await tester.pumpWidget(
    MaterialApp(
      home: ServicesScope(services: services, child: page),
    ),
  );
  await tester.pump();
}

/// Rebuilds, and waits for the tiles' colors, which change in an animation.
Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(kThemeChangeDuration);
}

Finder tile(String title) => find.widgetWithText(ListTile, title);

/// The color [title] is drawn in, in its list tile.
Color? colorOf(WidgetTester tester, String title) => tester
    .renderObject<RenderParagraph>(find.descendant(of: tile(title), matching: find.text(title)))
    .text
    .style
    ?.color;

Color primary(WidgetTester tester) => Theme.of(tester.element(find.byType(Scaffold).first)).colorScheme.primary;

Finder playingIcon(String title) => find.descendant(of: tile(title), matching: find.byIcon(Icons.graphic_eq));

void main() {
  testWidgets('on the album page, the song that plays stands out, with the equalizer for its number', (tester) async {
    final services = fakeServices();
    await pump(tester, services, const AlbumPage(album));
    expect(colorOf(tester, 'Dream On'), isNot(primary(tester)));
    expect(find.byIcon(Icons.graphic_eq), findsNothing);

    await services.connect.playSongs(songs, 1);
    await settle(tester);
    expect(colorOf(tester, 'Dream On'), primary(tester));
    expect(playingIcon('Dream On'), findsOneWidget);
    expect(find.descendant(of: tile('Dream On'), matching: find.text('2')), findsNothing);
    expect(colorOf(tester, 'Make It'), isNot(primary(tester)));
    expect(playingIcon('Make It'), findsNothing);
    expect(find.descendant(of: tile('Make It'), matching: find.text('1')), findsOneWidget);

    // Paused, it still stands out, with its number back, as in Spotify.
    await services.connect.pause();
    await settle(tester);
    expect(colorOf(tester, 'Dream On'), primary(tester));
    expect(playingIcon('Dream On'), findsNothing);
    expect(find.descendant(of: tile('Dream On'), matching: find.text('2')), findsOneWidget);

    await services.connect.playSongs(songs, 0);
    await settle(tester);
    expect(colorOf(tester, 'Dream On'), isNot(primary(tester)));
    expect(colorOf(tester, 'Make It'), primary(tester));
    expect(playingIcon('Make It'), findsOneWidget);
    await tester.pumpWidget(const SizedBox()); // stops the bar's timer
  });

  testWidgets('it stands out too when it plays on another device', (tester) async {
    final client = SegueClient(
      url: Uri.parse('ws://unused'),
      auth: const Auth.subsonic(username: 'a', token: 't', salt: 's'),
      device: const DeviceInfo(id: 'me', name: 'me', client: 'test', api: Api.subsonic, roles: [], capabilities: []),
    );
    client.devices['tv'] = Device(
      info: const DeviceInfo(
        id: 'tv',
        name: 'TV',
        client: 'test',
        api: Api.subsonic,
        roles: [Role.player],
        capabilities: [],
      ),
      online: true,
      state: StampedState(
        status: PlaybackStatus.playing,
        positionMs: 0,
        at: DateTime.now().millisecondsSinceEpoch,
        index: 0,
        queue: [for (final song in songs) song.toQueueItem()],
      ),
    );
    final services = fakeServices(client: client);
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    client.notifyListeners(); // as when the TV's state arrives
    await pump(tester, services, const AlbumPage(album));
    expect(colorOf(tester, 'Make It'), primary(tester));
    expect(playingIcon('Make It'), findsOneWidget);
    expect(colorOf(tester, 'Dream On'), isNot(primary(tester)));
    await tester.pumpWidget(const SizedBox()); // stops the bar's timer
  });

  testWidgets('in search results, the song that plays stands out, with the equalizer over its cover', (tester) async {
    final services = fakeServices();
    await services.connect.playSongs(songs, 1);
    await pump(
      tester,
      services,
      Scaffold(
        body: SearchResultsList(Future.value((artists: const <Artist>[], albums: const <Album>[], songs: songs))),
      ),
    );
    expect(colorOf(tester, 'Dream On'), primary(tester));
    expect(playingIcon('Dream On'), findsOneWidget);
    expect(colorOf(tester, 'Make It'), isNot(primary(tester)));
    expect(playingIcon('Make It'), findsNothing);
  });
}
