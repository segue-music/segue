import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../segue/protocol.dart';
import '../server/models.dart';
import '../server/server.dart';

/// Subsonic token authentication: the password never leaves the device, only md5(password + salt).
class SubsonicCredentials implements Credentials {
  const SubsonicCredentials({required this.username, required this.token, required this.salt});

  factory SubsonicCredentials.fromPassword(String username, String password) {
    final random = Random.secure();
    final salt = List.generate(12, (_) => random.nextInt(16).toRadixString(16)).join();
    return SubsonicCredentials(
      username: username,
      token: md5.convert(utf8.encode(password + salt)).toString(),
      salt: salt,
    );
  }

  @override
  final String username;
  final String token;
  final String salt;
}

/// The parts of the Subsonic API the app uses.
class SubsonicApi implements MediaServer {
  SubsonicApi(Uri server, this.credentials, {http.Client? client})
    : server = server.path.endsWith('/') ? server : server.replace(path: '${server.path}/'),
      _http = client ?? http.Client();

  final Uri server;
  @override
  final SubsonicCredentials credentials;
  final http.Client _http;

  @override
  Api get api => Api.subsonic;

  @override
  Auth get auth => Auth.subsonic(username: credentials.username, token: credentials.token, salt: credentials.salt);

  Future<void> ping() => _get('ping');

  /// Albums by name are getAlbumList2's alphabeticalByName; the latest added, its newest.
  @override
  Future<List<Album>> albums({required AlbumOrder order, int size = 100, int offset = 0}) => _albumList(
    switch (order) {
      AlbumOrder.latest => 'newest',
      AlbumOrder.name => 'alphabeticalByName',
    },
    size: size,
    offset: offset,
  );

  @override
  Future<List<Album>> mostPlayedAlbums({int size = 20}) => _albumList('frequent', size: size);

  /// Albums in a list type of getAlbumList2: newest, recent, frequent, random, alphabeticalByName…
  Future<List<Album>> _albumList(String type, {required int size, int offset = 0}) async {
    final body = await _get('getAlbumList2', {'type': type, 'size': '$size', 'offset': '$offset'});
    final list = (body['albumList2'] as Map<String, dynamic>?)?['album'] as List? ?? const [];
    return [for (final album in list) _album(album as Map<String, dynamic>)];
  }

  @override
  Future<(Album, List<Song>)> album(String id) async {
    final json = (await _get('getAlbum', {'id': id}))['album'] as Map<String, dynamic>;
    final songs = json['song'] as List? ?? const [];
    return (_album(json), [for (final song in songs) _song(song as Map<String, dynamic>)]);
  }

  /// Artists, albums and songs whose name, title or artist matches [query] (search3).
  @override
  Future<SearchResults> search(String query, {int artists = 5, int albums = 10, int songs = 50}) async {
    final body = await _get('search3', {
      'query': query,
      'artistCount': '$artists',
      'albumCount': '$albums',
      'songCount': '$songs',
    });
    final result = body['searchResult3'] as Map<String, dynamic>? ?? const {};
    return (
      artists: [for (final artist in result['artist'] as List? ?? const []) _artist(artist as Map<String, dynamic>)],
      albums: [for (final album in result['album'] as List? ?? const []) _album(album as Map<String, dynamic>)],
      songs: [for (final song in result['song'] as List? ?? const []) _song(song as Map<String, dynamic>)],
    );
  }

  /// Every artist, by name (getArtists, which groups them by letter).
  @override
  Future<List<Artist>> artists() async {
    final body = await _get('getArtists');
    final index = (body['artists'] as Map<String, dynamic>?)?['index'] as List? ?? const [];
    return [
      for (final letter in index)
        for (final artist in (letter as Map<String, dynamic>)['artist'] as List? ?? const [])
          _artist(artist as Map<String, dynamic>),
    ];
  }

  /// An artist and their albums (getArtist).
  @override
  Future<(Artist, List<Album>)> artist(String id) async {
    final json = (await _get('getArtist', {'id': id}))['artist'] as Map<String, dynamic>;
    final albums = json['album'] as List? ?? const [];
    return (_artist(json), [for (final album in albums) _album(album as Map<String, dynamic>)]);
  }

  @override
  Uri streamUrl(String songId) => _url('stream', {'id': songId});

  @override
  Uri coverArtUrl(String id, {int size = 300}) => _url('getCoverArt', {'id': id, 'size': '$size'});

  @override
  Future<Uint8List> coverArt(String id, {int size = 300}) async {
    final response = await _http.get(coverArtUrl(id, size: size));
    if (response.statusCode != 200 || !(response.headers['content-type'] ?? '').startsWith('image/')) {
      throw ServerError('no cover for $id (HTTP ${response.statusCode})');
    }
    return response.bodyBytes;
  }

  /// Subsonic keeps no sign-in: the token is good until the password changes.
  @override
  Future<void> signOut() async {}

  Uri _url(String endpoint, [Map<String, String> params = const {}]) => server
      .resolve('rest/$endpoint.view')
      .replace(
        queryParameters: {
          'u': credentials.username,
          't': credentials.token,
          's': credentials.salt,
          'v': '1.16.1',
          'c': clientName,
          'f': 'json',
          ...params,
        },
      );

  Future<Map<String, dynamic>> _get(String endpoint, [Map<String, String> params = const {}]) async {
    final response = await _http.get(_url(endpoint, params));
    if (response.statusCode != 200) {
      throw ServerError('${server.host}: HTTP ${response.statusCode}');
    }
    final body =
        (jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>)['subsonic-response']
            as Map<String, dynamic>;
    if (body['status'] != 'ok') {
      final error = body['error'] as Map<String, dynamic>?;
      final code = (error?['code'] as num?)?.toInt();
      // Code 40 is a wrong username or password.
      throw ServerError(error?['message'] as String? ?? 'request failed', isAuth: code == 40 || code == 41);
    }
    return body;
  }

  @override
  void close() => _http.close();
}

Album _album(Map<String, dynamic> json) => Album(
  id: json['id'] as String,
  name: json['name'] as String? ?? '',
  artist: json['artist'] as String?,
  coverArt: json['coverArt'] as String?,
  year: (json['year'] as num?)?.toInt(),
  songCount: (json['songCount'] as num?)?.toInt(),
);

Song _song(Map<String, dynamic> json) => Song(
  id: json['id'] as String,
  title: json['title'] as String? ?? '',
  artist: json['artist'] as String?,
  album: json['album'] as String?,
  coverArt: json['coverArt'] as String?,
  duration: json['duration'] == null ? null : Duration(seconds: (json['duration'] as num).toInt()),
);

Artist _artist(Map<String, dynamic> json) => Artist(
  id: json['id'] as String,
  name: json['name'] as String? ?? '',
  coverArt: json['coverArt'] as String?,
  albumCount: (json['albumCount'] as num?)?.toInt(),
);
