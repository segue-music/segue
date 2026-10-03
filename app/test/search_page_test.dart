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
import 'package:segue/ui/search_page.dart';

import 'fakes.dart';

void main() {
  testWidgets('searches once typing stops, and a song found plays the songs found from it', (tester) async {
    const credentials = SubsonicCredentials(username: 'a', token: 't', salt: 's');
    final queries = <String?>[];
    final api = SubsonicApi(
      Uri.parse('https://music.test'),
      credentials,
      client: MockClient((request) async {
        queries.add(request.url.queryParameters['query']);
        return http.Response(
          jsonEncode({
            'subsonic-response': {
              'status': 'ok',
              'searchResult3': {
                'album': [
                  {'id': 'a1', 'name': 'Aerosmith', 'artist': 'Aerosmith', 'year': 1973},
                ],
                'song': [
                  {'id': 's1', 'title': 'Dream On', 'artist': 'Aerosmith', 'album': 'Aerosmith', 'duration': 268},
                  {'id': 's2', 'title': 'Dream Police', 'artist': 'Cheap Trick', 'album': 'Heaven Tonight'},
                ],
              },
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    final player = PlayerController(FakeEngine(), api);
    final services = Services(
      Session(server: Uri.parse('https://music.test'), credentials: credentials, deviceId: 'me', deviceName: 'me'),
      api,
      player,
      ConnectController(player: player),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: ServicesScope(services: services, child: const SearchPage()),
      ),
    );
    await tester.enterText(find.byType(TextField), 'dre');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(find.byType(TextField), 'dream ');
    await tester.pump(SearchPage.typingPause);
    await tester.pump();
    expect(queries, ['dream']);
    expect(find.text('Aerosmith · 1973'), findsOneWidget);
    expect(find.text('Cheap Trick · Heaven Tonight'), findsOneWidget);
    expect(find.text('4:28'), findsOneWidget);

    await tester.tap(find.text('Dream Police'));
    await tester.pump();
    expect([for (final song in player.queue) song.id], ['s1', 's2']);
    expect(player.current?.id, 's2');
    expect(player.playing, isTrue);
    await tester.pumpWidget(const SizedBox()); // stops the bar's timer
  });
}
