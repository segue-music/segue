import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:segue/jellyfin/api.dart';
import 'package:segue/server/server.dart';

const credentials = JellyfinCredentials(username: 'alice', userId: 'u1', token: 'tok');

http.Response json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

http.Response items(List<Map<String, Object?>> items) => json({'Items': items, 'TotalRecordCount': items.length});

/// An API whose server answers with [answer]; [asked] gets every request.
JellyfinApi jellyfin(http.Response Function(http.Request request) answer, [List<http.Request>? asked]) => JellyfinApi(
  Uri.parse('https://music.test/jellyfin'),
  credentials,
  deviceId: 'd1',
  deviceName: 'laptop',
  client: MockClient((request) async {
    asked?.add(request);
    return answer(request);
  }),
);

const album = {
  'Id': 'a1',
  'Name': 'Toys in the Attic',
  'Type': 'MusicAlbum',
  'AlbumArtist': 'Aerosmith',
  'ProductionYear': 1975,
  'ChildCount': 9,
  'ImageTags': {'Primary': 'tag'},
};

const song = {
  'Id': 's1',
  'Name': 'Walk This Way',
  'Type': 'Audio',
  'Artists': ['Aerosmith'],
  'AlbumArtist': 'Aerosmith',
  'Album': 'Toys in the Attic',
  'AlbumId': 'a1',
  'AlbumPrimaryImageTag': 'tag',
  'RunTimeTicks': 2210000000,
  'ImageTags': <String, String>{},
};

const artist = {
  'Id': 'ar1',
  'Name': 'Aerosmith',
  'Type': 'MusicArtist',
  'ImageTags': {'Primary': 'tag'},
};

void main() {
  test('requests carry the token in the Authorization header, as this device', () async {
    final asked = <http.Request>[];
    await jellyfin((_) => items([]), asked).albums();
    expect(
      asked.single.headers['Authorization'],
      'MediaBrowser Client="Segue", Device="laptop", DeviceId="d1", Version="$appVersion", Token="tok"',
    );
    expect(asked.single.url.path, '/jellyfin/Items');
    expect(asked.single.url.queryParameters, containsPair('userId', 'u1'));
  });

  test('albums: the newest first, with their covers, artist, year and number of songs', () async {
    final asked = <http.Request>[];
    final albums = await jellyfin((_) => items([album]), asked).albums(size: 20, offset: 40);
    final query = asked.single.url.queryParameters;
    expect(query, containsPair('IncludeItemTypes', 'MusicAlbum'));
    expect(query, containsPair('Recursive', 'true'));
    expect(query['SortBy'], startsWith('DateCreated'));
    expect(query, containsPair('SortOrder', 'Descending'));
    expect(query, containsPair('Limit', '20'));
    expect(query, containsPair('StartIndex', '40'));
    final first = albums.single;
    expect(
      (first.id, first.name, first.artist, first.year, first.songCount),
      ('a1', 'Toys in the Attic', 'Aerosmith', 1975, 9),
    );
    expect(first.coverArt, 'a1');
  });

  test('most played albums: Jellyfin counts plays by song, so they add up by album', () async {
    Map<String, Object?> played(String id, String? albumId, int plays) => {
      ...song,
      'Id': id,
      'AlbumId': albumId,
      'UserData': {'PlayCount': plays, 'Played': true},
    };
    final asked = <http.Request>[];
    final albums = await jellyfin((request) {
      final query = request.url.queryParameters;
      if (query['IncludeItemTypes'] == 'Audio') {
        return items([
          played('s0', null, 20), // a song in no album
          played('s1', 'a1', 9),
          played('s2', 'a2', 6),
          played('s3', 'a2', 5),
          played('s4', 'a3', 1),
        ]);
      }
      // Asked by id, in whatever order the server likes.
      final ids = query['Ids']?.split(',') ?? const [];
      return items([
        for (final id in ids.reversed) {...album, 'Id': id, 'Name': 'Album $id'},
      ]);
    }, asked).mostPlayedAlbums(size: 2);
    expect([for (final album in albums) album.name], ['Album a2', 'Album a1']);
    final songs = asked.first.url.queryParameters;
    expect(songs, containsPair('Recursive', 'true'));
    expect(songs, containsPair('Filters', 'IsPlayed'));
    expect(songs, containsPair('SortBy', 'PlayCount'));
    expect(songs, containsPair('SortOrder', 'Descending'));
    expect(songs, contains('Limit'));
    expect(asked.last.url.queryParameters, containsPair('Ids', 'a2,a1'));
  });

  test('with nothing played yet there are no most played albums, and no albums to ask for', () async {
    final asked = <http.Request>[];
    expect(await jellyfin((_) => items([]), asked).mostPlayedAlbums(), isEmpty);
    expect(asked, hasLength(1));
  });

  test('an album and its songs, in order; a song without an image of its own shows its album\'s', () async {
    final asked = <http.Request>[];
    final (found, songs) = await jellyfin((request) {
      final query = request.url.queryParameters;
      if (query['Ids'] == 'a1') return items([album]);
      if (query['ParentId'] == 'a1') return items([song]);
      return http.Response('', 404);
    }, asked).album('a1');
    expect(found.name, 'Toys in the Attic');
    final tracks = asked.firstWhere((request) => request.url.queryParameters['ParentId'] == 'a1').url.queryParameters;
    expect(tracks, containsPair('IncludeItemTypes', 'Audio'));
    expect(tracks['SortBy'], startsWith('ParentIndexNumber,IndexNumber'));
    final first = songs.single;
    expect(
      (first.id, first.title, first.artist, first.album),
      ('s1', 'Walk This Way', 'Aerosmith', 'Toys in the Attic'),
    );
    expect(first.duration, const Duration(seconds: 221));
    expect(first.coverArt, 'a1');
  });

  test('search: artists, albums and songs that match', () async {
    final asked = <http.Request>[];
    final (:artists, :albums, :songs) = await jellyfin((request) {
      // Artists from their own endpoint: Jellyfin's Items doesn't list them.
      if (request.url.path == '/jellyfin/Artists/AlbumArtists') return items([artist]);
      return switch (request.url.queryParameters['IncludeItemTypes']) {
        'MusicAlbum' => items([album]),
        'Audio' => items([song]),
        _ => http.Response('', 404),
      };
    }, asked).search('aero');
    expect(asked.map((request) => request.url.queryParameters['searchTerm']), everyElement('aero'));
    expect(asked.map((request) => request.url.queryParameters['Limit']), unorderedEquals(['5', '10', '50']));
    expect(artists.single.name, 'Aerosmith');
    expect(artists.single.coverArt, 'ar1');
    expect(albums.single.name, 'Toys in the Attic');
    expect(songs.single.title, 'Walk This Way');
  });

  test('artists: the album artists, by name', () async {
    final asked = <http.Request>[];
    final artists = await jellyfin((_) => items([artist]), asked).artists();
    expect(asked.single.url.path, '/jellyfin/Artists/AlbumArtists');
    expect(asked.single.url.queryParameters, containsPair('SortBy', 'SortName'));
    expect(artists.single.id, 'ar1');
  });

  test('an artist and their albums', () async {
    final (found, albums) = await jellyfin((request) {
      final query = request.url.queryParameters;
      if (query['Ids'] == 'ar1') return items([artist]);
      if (query['AlbumArtistIds'] == 'ar1' && query['IncludeItemTypes'] == 'MusicAlbum') return items([album]);
      return http.Response('', 404);
    }).artist('ar1');
    expect(found.name, 'Aerosmith');
    expect(found.albumCount, 1);
    expect(albums.single.id, 'a1');
  });

  test('audio and covers come from URLs a player can open, the token in the stream\'s', () {
    final api = jellyfin((_) => http.Response('', 404));
    final stream = api.streamUrl('s1');
    expect(stream.path, '/jellyfin/Audio/s1/stream');
    expect(stream.queryParameters, containsPair('static', 'true'));
    expect(stream.queryParameters, containsPair('ApiKey', 'tok'));
    final cover = api.coverArtUrl('a1', size: 96);
    expect(cover.path, '/jellyfin/Items/a1/Images/Primary');
    expect(cover.queryParameters, containsPair('maxWidth', '96'));
  });

  test('a sign-in the server forgot is an auth error, also from pages that ask for two things at once', () async {
    final forgot = jellyfin((_) => http.Response('', 401));
    for (final request in [forgot.albums, () => forgot.album('a1'), () => forgot.search('aero')]) {
      await expectLater(request(), throwsA(isA<ServerError>().having((e) => e.isAuth, 'isAuth', isTrue)));
    }
  });

  test('signing out ends the sign-in on the server, and never fails', () async {
    final asked = <http.Request>[];
    await jellyfin((_) => http.Response('', 204), asked).signOut();
    expect((asked.single.method, asked.single.url.path), ('POST', '/jellyfin/Sessions/Logout'));
    expect(asked.single.headers['Authorization'], contains('Token="tok"'));
    await jellyfin((_) => throw http.ClientException('offline')).signOut();
  });
}
