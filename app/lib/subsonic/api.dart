import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'models.dart';

/// Subsonic token authentication: the password never leaves the device, only md5(password + salt).
class SubsonicCredentials {
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

  final String username;
  final String token;
  final String salt;
}

class SubsonicError implements Exception {
  const SubsonicError(this.code, this.message);

  final int? code;
  final String message;

  /// Code 40 is a wrong username or password.
  bool get isAuth => code == 40 || code == 41;

  @override
  String toString() => message;
}

/// The parts of the Subsonic API the app uses.
class SubsonicApi {
  SubsonicApi(Uri server, this.credentials, {http.Client? client})
    : server = server.path.endsWith('/') ? server : server.replace(path: '${server.path}/'),
      _http = client ?? http.Client();

  static const clientName = 'Segue';

  final Uri server;
  final SubsonicCredentials credentials;
  final http.Client _http;

  Future<void> ping() => _get('ping');

  /// Albums in a list type of getAlbumList2: newest, recent, frequent, random, alphabeticalByName…
  Future<List<Album>> albums({String type = 'newest', int size = 100, int offset = 0}) async {
    final body = await _get('getAlbumList2', {'type': type, 'size': '$size', 'offset': '$offset'});
    final list = (body['albumList2'] as Map<String, dynamic>?)?['album'] as List? ?? const [];
    return [for (final album in list) Album.fromJson(album as Map<String, dynamic>)];
  }

  Future<(Album, List<Song>)> album(String id) async {
    final json = (await _get('getAlbum', {'id': id}))['album'] as Map<String, dynamic>;
    final songs = json['song'] as List? ?? const [];
    return (Album.fromJson(json), [for (final song in songs) Song.fromJson(song as Map<String, dynamic>)]);
  }

  Uri streamUrl(String songId) => _url('stream', {'id': songId});

  Uri coverArtUrl(String id, {int size = 300}) => _url('getCoverArt', {'id': id, 'size': '$size'});

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
      throw SubsonicError(null, '${server.host}: HTTP ${response.statusCode}');
    }
    final body =
        (jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>)['subsonic-response']
            as Map<String, dynamic>;
    if (body['status'] != 'ok') {
      final error = body['error'] as Map<String, dynamic>?;
      throw SubsonicError((error?['code'] as num?)?.toInt(), error?['message'] as String? ?? 'request failed');
    }
    return body;
  }

  void close() => _http.close();
}
