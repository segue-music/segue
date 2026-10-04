import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:segue/connect/connect.dart';
import 'package:segue/player/player.dart';
import 'package:segue/services.dart';
import 'package:segue/session.dart';
import 'package:segue/subsonic/api.dart';
import 'package:segue/ui/home_page.dart';

import 'fakes.dart';

http.Response subsonic(Map<String, Object?> body) => http.Response(
  jsonEncode({
    'subsonic-response': {'status': 'ok', ...body},
  }),
  200,
  headers: {'content-type': 'application/json'},
);

/// The home page on a screen of [size], over a fake server. Returns the player and the searches asked.
Future<(PlayerController, List<String?>)> pumpHome(WidgetTester tester, Size size) async {
  const credentials = SubsonicCredentials(username: 'a', token: 't', salt: 's');
  final queries = <String?>[];
  final api = SubsonicApi(
    Uri.parse('https://music.test'),
    credentials,
    client: MockClient((request) async {
      if (request.url.path.endsWith('getAlbumList2.view')) {
        return subsonic({
          'albumList2': {
            'album': [
              {'id': 'a9', 'name': 'Toys in the Attic', 'artist': 'Aerosmith'},
            ],
          },
        });
      }
      queries.add(request.url.queryParameters['query']);
      return subsonic({
        'searchResult3': {
          'album': [
            {'id': 'a1', 'name': 'Aerosmith', 'artist': 'Aerosmith', 'year': 1973},
          ],
          'song': [
            {'id': 's1', 'title': 'Dream On', 'artist': 'Aerosmith', 'album': 'Aerosmith', 'duration': 268},
            {'id': 's2', 'title': 'Dream Police', 'artist': 'Cheap Trick', 'album': 'Heaven Tonight'},
          ],
        },
      });
    }),
  );
  final player = PlayerController(FakeEngine(), api);
  final services = Services(
    Session(server: Uri.parse('https://music.test'), credentials: credentials, deviceId: 'me', deviceName: 'me'),
    api,
    player,
    ConnectController(player: player),
  );
  // The screen itself, not just the surface: the page picks its layout from MediaQuery.
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: ServicesScope(
        services: services,
        child: HomePage(onSignOut: () {}),
      ),
    ),
  );
  await tester.pump();
  return (player, queries);
}

void main() {
  testWidgets('on a phone-sized screen, the bar searches once typing stops, in place of the albums', (tester) async {
    final (player, queries) = await pumpHome(tester, const Size(360, 640));
    expect(find.text('Toys in the Attic'), findsOneWidget);
    expect(find.byTooltip('Limpar'), findsNothing);
    // The bar has a line of its own, under the title.
    expect(tester.getCenter(find.byType(TextField)).dy, greaterThan(tester.getBottomLeft(find.text('Álbuns')).dy));

    await tester.enterText(find.byType(TextField), 'dre');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(find.byType(TextField), 'dream ');
    await tester.pump(HomePage.searchTypingPause);
    await tester.pump();
    expect(queries, ['dream']);
    expect(find.text('Toys in the Attic'), findsNothing);
    expect(find.text('Aerosmith · 1973'), findsOneWidget);
    expect(find.text('Cheap Trick · Heaven Tonight'), findsOneWidget);
    expect(find.text('4:28'), findsOneWidget);

    await tester.tap(find.text('Dream Police'));
    await tester.pump();
    expect([for (final song in player.queue) song.id], ['s1', 's2']);
    expect(player.current?.id, 's2');
    expect(player.playing, isTrue);

    await tester.tap(find.byTooltip('Limpar'));
    await tester.pump();
    expect(find.text('Toys in the Attic'), findsOneWidget);
    expect(find.text('Aerosmith · 1973'), findsNothing);
    expect(queries, ['dream']);
    await tester.pumpWidget(const SizedBox()); // stops the bar's timer
  });

  testWidgets('on a wide screen, the bar sits next to the title', (tester) async {
    await pumpHome(tester, const Size(1000, 640));
    final title = tester.getRect(find.text('Álbuns'));
    final field = tester.getRect(find.byType(TextField));
    expect(field.left, greaterThan(title.right));
    expect(field.center.dy, moreOrLessEquals(title.center.dy, epsilon: 4));
    await tester.pumpWidget(const SizedBox()); // stops the bar's timer
  });
}
