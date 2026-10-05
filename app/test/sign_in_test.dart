import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:segue/jellyfin/api.dart';
import 'package:segue/segue/protocol.dart';
import 'package:segue/server/server.dart';
import 'package:segue/server/sign_in.dart';
import 'package:segue/subsonic/api.dart';

http.Response json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

/// Navidrome's answer to a ping without credentials.
final missingCredentials = json({
  'subsonic-response': {
    'status': 'failed',
    'version': '1.16.1',
    'type': 'navidrome',
    'openSubsonic': true,
    'error': {'code': 10, 'message': 'Required parameter is missing'},
  },
});

final jellyfinInfo = json({
  'ServerName': 'music',
  'Version': '10.10.7',
  'ProductName': 'Jellyfin Server',
  'Id': '4f6e1b2c3d4e5f60718293a4b5c6d7e8',
});

/// A media server that answers [routes] (by path) and 404 to the rest.
MockClient server(Map<String, http.Response Function(http.Request request)> routes) =>
    MockClient((request) async => routes[request.url.path]?.call(request) ?? http.Response('<!doctype html>', 404));

void main() {
  group('detectApi', () {
    test('a Subsonic server answers a ping, even without credentials', () async {
      final client = server({'/rest/ping.view': (_) => missingCredentials});
      expect(await detectApi(Uri.parse('https://music.test'), client: client), Api.subsonic);
    });

    test('a Jellyfin server answers with its public info, under its path', () async {
      final client = server({'/jellyfin/System/Info/Public': (_) => jellyfinInfo});
      expect(await detectApi(Uri.parse('https://music.test/jellyfin'), client: client), Api.jellyfin);
    });

    test('a server with both APIs at the same address is taken as Subsonic', () async {
      final client = server({'/rest/ping.view': (_) => missingCredentials, '/System/Info/Public': (_) => jellyfinInfo});
      expect(await detectApi(Uri.parse('https://music.test'), client: client), Api.subsonic);
    });

    test('a website is no media server', () async {
      final client = MockClient((_) async => http.Response('<!doctype html><title>Hi</title>', 200));
      await expectLater(detectApi(Uri.parse('https://example.test'), client: client), throwsA(isA<NotAMediaServer>()));
    });

    test('a server that can\'t be reached is not "no media server"', () async {
      final down = MockClient((_) async => throw http.ClientException('Connection refused'));
      await expectLater(detectApi(Uri.parse('https://music.test'), client: down), throwsA(isA<http.ClientException>()));
      final starting = MockClient((_) async => http.Response('Bad Gateway', 502));
      await expectLater(
        detectApi(Uri.parse('https://music.test'), client: starting),
        throwsA(isA<ServerError>().having((e) => e.isAuth, 'isAuth', isFalse)),
      );
    });

    test('a server that can\'t be reached is asked only once', () async {
      // Like a timeout, which a second question to the same address would only wait for again.
      final asked = <String>[];
      final down = MockClient((request) async {
        asked.add(request.url.path);
        throw http.ClientException('Connection timed out');
      });
      await expectLater(detectApi(Uri.parse('https://music.test'), client: down), throwsA(isA<http.ClientException>()));
      expect(asked, ['/rest/ping.view']);
    });
  });

  group('signIn', () {
    test('on a Subsonic server, checks the password as a token', () async {
      late Uri pinged;
      final client = server({
        '/rest/ping.view': (request) {
          if (!request.url.queryParameters.containsKey('t')) return missingCredentials;
          pinged = request.url;
          return json({
            'subsonic-response': {'status': 'ok'},
          });
        },
      });
      final api = await signIn(
        Uri.parse('https://music.test'),
        'alice',
        'sesame',
        deviceId: 'd1',
        deviceName: 'laptop',
        client: client,
      );
      expect(api, isA<SubsonicApi>());
      expect(api.credentials.username, 'alice');
      expect(pinged.queryParameters, containsPair('u', 'alice'));
      expect(pinged.queryParameters.containsKey('p'), isFalse);
    });

    test('on a Jellyfin server, signs in by name as this device', () async {
      late http.Request asked;
      final client = server({
        '/System/Info/Public': (_) => jellyfinInfo,
        '/Users/AuthenticateByName': (request) {
          asked = request;
          return json({
            'User': {'Name': 'Alice', 'Id': '5f1c0e2a9b8d4c7e8f6a5b4c3d2e1f00'},
            'AccessToken': 'f0e1d2c3b4a5968778695a4b3c2d1e0f',
            'ServerId': '4f6e1b2c3d4e5f60718293a4b5c6d7e8',
          });
        },
      });
      final api = await signIn(
        Uri.parse('https://music.test'),
        'alice',
        'sesame',
        deviceId: 'd1',
        deviceName: 'Living room',
        client: client,
      );
      expect(asked.method, 'POST');
      expect(jsonDecode(asked.body), {'Username': 'alice', 'Pw': 'sesame'});
      expect(
        asked.headers['Authorization'],
        'MediaBrowser Client="Segue", Device="Living%20room", DeviceId="d1", Version="$appVersion"',
      );
      expect(api, isA<JellyfinApi>());
      final credentials = api.credentials as JellyfinCredentials;
      expect(credentials.username, 'Alice'); // as the server spells it
      expect(credentials.userId, '5f1c0e2a9b8d4c7e8f6a5b4c3d2e1f00');
      expect(credentials.token, 'f0e1d2c3b4a5968778695a4b3c2d1e0f');
      expect(api.api, Api.jellyfin);
      expect(api.auth.toJson(), {'scheme': 'jellyfin', 'token': 'f0e1d2c3b4a5968778695a4b3c2d1e0f'});
    });

    test('a wrong password is an auth error, in either API', () async {
      final subsonic = server({
        '/rest/ping.view': (request) => request.url.queryParameters.containsKey('t')
            ? json({
                'subsonic-response': {
                  'status': 'failed',
                  'error': {'code': 40, 'message': 'Wrong username or password'},
                },
              })
            : missingCredentials,
      });
      final jellyfin = server({
        '/System/Info/Public': (_) => jellyfinInfo,
        '/Users/AuthenticateByName': (_) => http.Response('Error processing request.', 401),
      });
      for (final client in [subsonic, jellyfin]) {
        await expectLater(
          signIn(
            Uri.parse('https://music.test'),
            'alice',
            'wrong',
            deviceId: 'd1',
            deviceName: 'laptop',
            client: client,
          ),
          throwsA(isA<ServerError>().having((e) => e.isAuth, 'isAuth', isTrue)),
        );
      }
    });
  });

  test('a saved sign-in opens in its API', () {
    const jellyfin = JellyfinCredentials(username: 'alice', userId: 'u1', token: 't1');
    const subsonic = SubsonicCredentials(username: 'alice', token: 't', salt: 's');
    final server = Uri.parse('https://music.test');
    expect(openServer(server, jellyfin, deviceId: 'd1', deviceName: 'laptop').api, Api.jellyfin);
    expect(openServer(server, subsonic, deviceId: 'd1', deviceName: 'laptop').api, Api.subsonic);
  });
}
