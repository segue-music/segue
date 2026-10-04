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

/// A server with two artists: Aerosmith, with two albums, and Cheap Trick.
http.Response server(http.Request request) {
  final path = request.url.path;
  if (path.endsWith('getAlbumList2.view')) return subsonic({'albumList2': <String, Object?>{}});
  if (path.endsWith('getArtists.view')) {
    return subsonic({
      'artists': {
        'index': [
          {
            'name': 'A',
            'artist': [
              {'id': 'ar1', 'name': 'Aerosmith', 'albumCount': 2},
            ],
          },
          {
            'name': 'C',
            'artist': [
              {'id': 'ar2', 'name': 'Cheap Trick', 'albumCount': 1},
            ],
          },
        ],
      },
    });
  }
  if (path.endsWith('getArtist.view')) {
    return subsonic({
      'artist': {
        'id': 'ar1',
        'name': 'Aerosmith',
        'albumCount': 2,
        'album': [
          {'id': 'a1', 'name': 'Aerosmith', 'artist': 'Aerosmith', 'year': 1973},
          {'id': 'a2', 'name': 'Toys in the Attic', 'artist': 'Aerosmith', 'year': 1975},
        ],
      },
    });
  }
  if (path.endsWith('getAlbum.view')) {
    return subsonic({
      'album': {
        'id': 'a2',
        'name': 'Toys in the Attic',
        'artist': 'Aerosmith',
        'song': [
          {'id': 's1', 'title': 'Walk This Way', 'artist': 'Aerosmith', 'duration': 220},
        ],
      },
    });
  }
  if (path.endsWith('search3.view')) {
    return subsonic({
      'searchResult3': {
        'artist': [
          {'id': 'ar1', 'name': 'Aerosmith', 'albumCount': 2},
        ],
      },
    });
  }
  return http.Response('', 404);
}

Future<void> pumpHome(WidgetTester tester, Size size) async {
  const credentials = SubsonicCredentials(username: 'a', token: 't', salt: 's');
  final api = SubsonicApi(
    Uri.parse('https://music.test'),
    credentials,
    client: MockClient((request) async => server(request)),
  );
  final player = PlayerController(FakeEngine(), api);
  final services = Services(
    Session(server: Uri.parse('https://music.test'), credentials: credentials, deviceId: 'me', deviceName: 'me'),
    api,
    player,
    ConnectController(player: player),
  );
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => ServicesScope(services: services, child: child!),
      home: HomePage(onSignOut: () {}),
    ),
  );
  await tester.pumpAndSettle();
}

Finder title(String text) => find.descendant(of: find.byType(AppBar), matching: find.text(text));

void main() {
  testWidgets('on a wide screen, a side rail goes to the artists, and an artist shows their albums, newest first', (
    tester,
  ) async {
    await pumpHome(tester, const Size(1000, 700));
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    expect(title('Álbuns'), findsOneWidget);

    await tester.tap(find.descendant(of: find.byType(NavigationRail), matching: find.text('Artistas')));
    await tester.pumpAndSettle();
    expect(title('Artistas'), findsOneWidget);
    expect(find.text('Aerosmith'), findsOneWidget);
    expect(find.text('Cheap Trick'), findsOneWidget);
    expect(find.text('2 álbuns'), findsOneWidget);
    expect(find.text('1 álbum'), findsOneWidget);

    await tester.tap(find.text('Aerosmith'));
    await tester.pumpAndSettle();
    expect(title('Aerosmith'), findsOneWidget);
    final newer = tester.getTopLeft(find.text('Toys in the Attic'));
    final older = tester.getTopLeft(find.text('1973'));
    expect(newer.dx < older.dx || newer.dy < older.dy, isTrue, reason: 'the 1975 album comes first');

    await tester.tap(find.text('Toys in the Attic'));
    await tester.pumpAndSettle();
    expect(find.text('Walk This Way'), findsOneWidget);
    await tester.pumpWidget(const SizedBox()); // stops the player bar's timers
  });

  testWidgets('on a phone, the sections are in a bar at the bottom', (tester) async {
    await pumpHome(tester, const Size(360, 640));
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationRail), findsNothing);
    await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Artistas')));
    await tester.pumpAndSettle();
    expect(title('Artistas'), findsOneWidget);
    expect(find.text('Cheap Trick'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('search finds artists too, and one opens their page', (tester) async {
    await pumpHome(tester, const Size(1000, 700));
    await tester.enterText(find.byType(TextField), 'aero');
    await tester.pump(HomePage.searchTypingPause);
    await tester.pumpAndSettle();
    expect(find.text('Artistas'), findsWidgets);
    await tester.tap(find.text('Aerosmith'));
    await tester.pumpAndSettle();
    expect(title('Aerosmith'), findsOneWidget);
    expect(find.text('Toys in the Attic'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
