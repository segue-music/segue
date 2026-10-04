import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:segue/server/server.dart';
import 'package:segue/subsonic/api.dart';

http.Response subsonic(Map<String, Object?> body) =>
    http.Response(jsonEncode({'subsonic-response': body}), 200, headers: {'content-type': 'application/json'});

void main() {
  const credentials = SubsonicCredentials(username: 'alice', token: '26719a1196d2a940705a59634eb18eab', salt: 'c19b2d');

  test('the token is md5(password + salt), as in the Subsonic docs', () {
    final fresh = SubsonicCredentials.fromPassword('alice', 'sesame');
    expect(fresh.token, md5.convert(utf8.encode('sesame${fresh.salt}')).toString());
    expect(md5.convert(utf8.encode('sesamec19b2d')).toString(), credentials.token);
  });

  test('requests carry the token, never the password, under the app name', () async {
    late Uri asked;
    final api = SubsonicApi(
      Uri.parse('https://music.test:4533'),
      credentials,
      client: MockClient((request) async {
        asked = request.url;
        return subsonic({'status': 'ok'});
      }),
    );
    await api.ping();
    expect(asked.path, '/rest/ping.view');
    expect(asked.queryParameters, containsPair('t', credentials.token));
    expect(asked.queryParameters, containsPair('s', credentials.salt));
    expect(asked.queryParameters, containsPair('c', 'Segue'));
    expect(asked.queryParameters.containsKey('p'), isFalse);
  });

  test('a server under a path keeps it', () {
    final api = SubsonicApi(Uri.parse('https://example.test/music'), credentials);
    expect(api.streamUrl('s1').path, '/music/rest/stream.view');
  });

  test('wrong credentials are an auth error', () async {
    final api = SubsonicApi(
      Uri.parse('https://music.test'),
      credentials,
      client: MockClient(
        (_) async => subsonic({
          'status': 'failed',
          'error': {'code': 40, 'message': 'Wrong username or password'},
        }),
      ),
    );
    await expectLater(api.ping(), throwsA(isA<ServerError>().having((e) => e.isAuth, 'isAuth', isTrue)));
  });

  test('albums and an album with its songs', () async {
    final api = SubsonicApi(
      Uri.parse('https://music.test'),
      credentials,
      client: MockClient((request) async {
        if (request.url.path.endsWith('getAlbumList2.view')) {
          return subsonic({
            'status': 'ok',
            'albumList2': {
              'album': [
                {'id': 'a1', 'name': 'Aerosmith', 'artist': 'Aerosmith', 'coverArt': 'al-a1', 'year': 1973},
              ],
            },
          });
        }
        return subsonic({
          'status': 'ok',
          'album': {
            'id': 'a1',
            'name': 'Aerosmith',
            'song': [
              {'id': 's1', 'title': 'Dream On', 'artist': 'Aerosmith', 'duration': 268},
            ],
          },
        });
      }),
    );
    final albums = await api.albums();
    expect(albums.single.name, 'Aerosmith');
    expect(albums.single.year, 1973);
    final (_, songs) = await api.album('a1');
    expect(songs.single.title, 'Dream On');
    expect(songs.single.duration, const Duration(seconds: 268));
    expect(songs.single.toQueueItem().durationMs, 268000);
  });

  test('search asks for artists, albums and songs', () async {
    late Uri asked;
    final api = SubsonicApi(
      Uri.parse('https://music.test'),
      credentials,
      client: MockClient((request) async {
        asked = request.url;
        return subsonic({
          'status': 'ok',
          'searchResult3': {
            'artist': [
              {'id': 'ar1', 'name': 'Aerosmith', 'coverArt': 'ar-ar1', 'albumCount': 2},
            ],
            'album': [
              {'id': 'a1', 'name': 'Aerosmith', 'artist': 'Aerosmith'},
            ],
            'song': [
              {'id': 's1', 'title': 'Dream On', 'artist': 'Aerosmith', 'album': 'Aerosmith', 'coverArt': 'mf-s1'},
            ],
          },
        });
      }),
    );
    final (:artists, :albums, :songs) = await api.search('dream on');
    expect(asked.path, '/rest/search3.view');
    expect(asked.queryParameters, containsPair('query', 'dream on'));
    expect(int.parse(asked.queryParameters['artistCount']!), greaterThan(0));
    expect(artists.single.name, 'Aerosmith');
    expect(artists.single.albumCount, 2);
    expect(albums.single.id, 'a1');
    expect(songs.single.coverArt, 'mf-s1');
  });

  test('artists come in name order, from every letter of the index', () async {
    late Uri asked;
    final api = SubsonicApi(
      Uri.parse('https://music.test'),
      credentials,
      client: MockClient((request) async {
        asked = request.url;
        return subsonic({
          'status': 'ok',
          'artists': {
            'ignoredArticles': 'The',
            'index': [
              {
                'name': 'A',
                'artist': [
                  {'id': 'ar1', 'name': 'Aerosmith', 'coverArt': 'ar-ar1', 'albumCount': 5},
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
      }),
    );
    final artists = await api.artists();
    expect(asked.path, '/rest/getArtists.view');
    expect(artists.map((artist) => artist.name), ['Aerosmith', 'Cheap Trick']);
    expect(artists.first.coverArt, 'ar-ar1');
    expect(artists.first.albumCount, 5);
  });

  test('an artist comes with their albums', () async {
    late Uri asked;
    final api = SubsonicApi(
      Uri.parse('https://music.test'),
      credentials,
      client: MockClient((request) async {
        asked = request.url;
        return subsonic({
          'status': 'ok',
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
      }),
    );
    final (artist, albums) = await api.artist('ar1');
    expect(asked.path, '/rest/getArtist.view');
    expect(asked.queryParameters, containsPair('id', 'ar1'));
    expect(artist.name, 'Aerosmith');
    expect(albums.map((album) => album.name), ['Aerosmith', 'Toys in the Attic']);
  });

  test('a search that finds nothing', () async {
    final api = SubsonicApi(
      Uri.parse('https://music.test'),
      credentials,
      client: MockClient((_) async => subsonic({'status': 'ok', 'searchResult3': <String, Object?>{}})),
    );
    final (artists: _, :albums, :songs) = await api.search('zzz');
    expect(albums, isEmpty);
    expect(songs, isEmpty);
  });
}
