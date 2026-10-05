import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../segue/protocol.dart';
import '../server/models.dart';
import '../server/server.dart';

/// A Jellyfin sign-in: the access token the server gave this device for the user. The password
/// isn't kept.
class JellyfinCredentials implements Credentials {
  const JellyfinCredentials({required this.username, required this.userId, required this.token});

  @override
  final String username;
  final String userId;
  final String token;
}

/// The parts of the Jellyfin API the app uses. Jellyfin keeps a sign-in per device, so requests say
/// which device they come from.
class JellyfinApi implements MediaServer {
  JellyfinApi(Uri server, this.credentials, {required this.deviceId, required this.deviceName, http.Client? client})
    : server = _withSlash(server),
      _http = client ?? http.Client();

  /// Signs in as [username] with [password] (Users/AuthenticateByName), as this device.
  static Future<JellyfinApi> signIn(
    Uri server,
    String username,
    String password, {
    required String deviceId,
    required String deviceName,
    http.Client? client,
  }) async {
    final http_ = client ?? http.Client();

    try {
      final response = await http_.post(
        _withSlash(server).resolve('Users/AuthenticateByName'),
        headers: {'Authorization': _authorization(deviceId, deviceName), 'Content-Type': 'application/json'},
        body: jsonEncode({'Username': username, 'Pw': password}),
      );
      final json = _decode(server, response) as Map<String, dynamic>;
      final user = json['User'] as Map<String, dynamic>;
      return JellyfinApi(
        server,
        JellyfinCredentials(
          username: user['Name'] as String,
          userId: user['Id'] as String,
          token: json['AccessToken'] as String,
        ),
        deviceId: deviceId,
        deviceName: deviceName,
        client: http_,
      );
    } on Object {
      if (client == null) {
        http_.close();
      }

      rethrow;
    }
  }

  final Uri server;
  @override
  final JellyfinCredentials credentials;
  final String deviceId;
  final String deviceName;
  final http.Client _http;

  @override
  Api get api => Api.jellyfin;

  @override
  Auth get auth => Auth.jellyfin(token: credentials.token);

  @override
  Future<List<Album>> albums({required AlbumOrder order, int size = 100, int offset = 0}) async => [
    for (final json in await _items({
      'IncludeItemTypes': 'MusicAlbum',
      ...switch (order) {
        AlbumOrder.latest => {'SortBy': 'DateCreated,SortName', 'SortOrder': 'Descending'},
        AlbumOrder.name => {'SortBy': 'SortName', 'SortOrder': 'Ascending'},
      },
      'Limit': '$size',
      'StartIndex': '$offset',
    }))
      _album(json),
  ];

  /// Jellyfin counts plays only by song: an album's are those of its songs, added up, among the user's
  /// most played songs. A tie goes to the album with the more played song.
  @override
  Future<List<Album>> mostPlayedAlbums({int size = 20}) async {
    final songs = await _items({
      'IncludeItemTypes': 'Audio',
      'Filters': 'IsPlayed',
      'SortBy': 'PlayCount',
      'SortOrder': 'Descending',
      'Limit': '1000',
    });
    final plays = <String, int>{};

    for (final song in songs) {
      final album = song['AlbumId'] as String?;
      final count = ((song['UserData'] as Map<String, dynamic>?)?['PlayCount'] as num?)?.toInt() ?? 0;

      if (album != null) {
        plays[album] = (plays[album] ?? 0) + count;
      }
    }

    final ranked = [
      for (final (i, MapEntry(key: id, value: count)) in plays.entries.indexed) (id: id, count: count, i: i),
    ]..sort((a, b) => a.count != b.count ? b.count.compareTo(a.count) : a.i.compareTo(b.i));
    final ids = [for (final album in ranked.take(size)) album.id];

    if (ids.isEmpty) {
      return const [];
    }

    // Asked by id, they come in whatever order.
    final albums = {
      for (final json in await _items({'Ids': ids.join(',')})) json['Id'] as String: _album(json),
    };
    return [for (final id in ids) ?albums[id]];
  }

  @override
  Future<(Album, List<Song>)> album(String id) async {
    // Future.wait throws the first failure as it came, where a record's wait would wrap it.
    final [albums, songs] = await Future.wait([
      _items({'Ids': id}),
      _items({'ParentId': id, 'IncludeItemTypes': 'Audio', 'SortBy': 'ParentIndexNumber,IndexNumber,SortName'}),
    ]);
    return (_album(_only(albums, id)), [for (final json in songs) _song(json)]);
  }

  @override
  Future<SearchResults> search(String query, {int artists = 5, int albums = 10, int songs = 50}) async {
    final [foundArtists, foundAlbums, foundSongs] = await Future.wait([
      _albumArtists({'searchTerm': query, 'Limit': '$artists'}),
      _items({'searchTerm': query, 'IncludeItemTypes': 'MusicAlbum', 'Limit': '$albums'}),
      _items({'searchTerm': query, 'IncludeItemTypes': 'Audio', 'Limit': '$songs'}),
    ]);
    return (
      artists: [for (final json in foundArtists) _artist(json)],
      albums: [for (final json in foundAlbums) _album(json)],
      songs: [for (final json in foundSongs) _song(json)],
    );
  }

  /// Every album artist, by name, as Subsonic's getArtists lists them.
  @override
  Future<List<Artist>> artists() async => [
    for (final json in await _albumArtists({'SortBy': 'SortName'})) _artist(json),
  ];

  /// An artist and the albums they are the album artist of.
  @override
  Future<(Artist, List<Album>)> artist(String id) async {
    final [artists, albums] = await Future.wait([
      _items({'Ids': id}),
      _items({'AlbumArtistIds': id, 'IncludeItemTypes': 'MusicAlbum', 'SortBy': 'ProductionYear,SortName'}),
    ]);
    final found = _artist(_only(artists, id));
    return (
      Artist(id: found.id, name: found.name, coverArt: found.coverArt, albumCount: albums.length),
      [for (final json in albums) _album(json)],
    );
  }

  /// The file as it is (static), with the token in the URL: the player can't send headers.
  @override
  Uri streamUrl(String songId) => _url('Audio/$songId/stream', {'static': 'true', 'ApiKey': credentials.token});

  /// Jellyfin serves images without a sign-in.
  @override
  Uri coverArtUrl(String id, {int size = 300}) =>
      _url('Items/$id/Images/Primary', {'maxWidth': '$size', 'maxHeight': '$size', 'quality': '90'});

  @override
  Future<Uint8List> coverArt(String id, {int size = 300}) async {
    final response = await _http.get(coverArtUrl(id, size: size));

    if (response.statusCode != 200 || !(response.headers['content-type'] ?? '').startsWith('image/')) {
      throw ServerError('no cover for $id (HTTP ${response.statusCode})');
    }

    return response.bodyBytes;
  }

  /// Ends this device's sign-in (Sessions/Logout), so that its token stops working.
  @override
  Future<void> signOut() async {
    try {
      await _http.post(_url('Sessions/Logout'), headers: _headers).timeout(const Duration(seconds: 5));
    } on Object {
      // offline, or the server forgot the sign-in already
    }
  }

  @override
  void close() => _http.close();

  Map<String, String> get _headers => {'Authorization': _authorization(deviceId, deviceName, credentials.token)};

  /// The user's items, at any depth, that match [query]; or by their ids (Ids), which every version
  /// takes, unlike Items/{id}.
  Future<List<Map<String, dynamic>>> _items(Map<String, String> query) =>
      _list('Items', {'Recursive': 'true', ...query});

  /// Artists come from their own endpoint: Jellyfin's Items doesn't list them.
  Future<List<Map<String, dynamic>>> _albumArtists(Map<String, String> query) => _list('Artists/AlbumArtists', query);

  Future<List<Map<String, dynamic>>> _list(String path, Map<String, String> query) async {
    final json = await _get(path, {'userId': credentials.userId, ...query});
    return [for (final item in (json as Map<String, dynamic>)['Items'] as List? ?? const []) item];
  }

  static Map<String, dynamic> _only(List<Map<String, dynamic>> items, String id) =>
      items.isEmpty ? throw ServerError('no item $id') : items.first;

  Future<Object?> _get(String path, Map<String, String> query) async =>
      _decode(server, await _http.get(_url(path, query), headers: _headers));

  Uri _url(String path, [Map<String, String>? query]) => server.resolve(path).replace(queryParameters: query);

  static Object? _decode(Uri server, http.Response response) {
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw const ServerError('the server refused the sign-in', isAuth: true);
    }

    if (response.statusCode != 200) {
      throw ServerError('${server.host}: HTTP ${response.statusCode}');
    }

    return jsonDecode(utf8.decode(response.bodyBytes));
  }

  static Uri _withSlash(Uri server) => server.path.endsWith('/') ? server : server.replace(path: '${server.path}/');

  /// The header that tells Jellyfin which app and device a request comes from, and with which sign-in.
  /// The values are URL-encoded, as Jellyfin's own clients do.
  static String _authorization(String deviceId, String deviceName, [String? token]) {
    final fields = {
      'Client': clientName,
      'Device': deviceName,
      'DeviceId': deviceId,
      'Version': appVersion,
      'Token': ?token,
    };
    final pairs = [for (final MapEntry(:key, :value) in fields.entries) '$key="${Uri.encodeComponent(value)}"'];
    return 'MediaBrowser ${pairs.join(', ')}';
  }
}

String? _primaryImage(Map<String, dynamic> json) =>
    (json['ImageTags'] as Map<String, dynamic>?)?['Primary'] == null ? null : json['Id'] as String;

String? _joined(Object? names) => names is List && names.isNotEmpty ? names.join(', ') : null;

Duration? _duration(Map<String, dynamic> json) {
  final ticks = json['RunTimeTicks'] as num?; // 10 million to the second
  return ticks == null ? null : Duration(microseconds: ticks.toInt() ~/ 10);
}

Album _album(Map<String, dynamic> json) => Album(
  id: json['Id'] as String,
  name: json['Name'] as String? ?? '',
  artist: json['AlbumArtist'] as String? ?? _joined(json['Artists']),
  coverArt: _primaryImage(json),
  year: (json['ProductionYear'] as num?)?.toInt(),
  songCount: (json['ChildCount'] as num?)?.toInt(),
);

/// A song's cover is its own image or else its album's, as Jellyfin's apps show it.
Song _song(Map<String, dynamic> json) => Song(
  id: json['Id'] as String,
  title: json['Name'] as String? ?? '',
  artist: _joined(json['Artists']) ?? json['AlbumArtist'] as String?,
  album: json['Album'] as String?,
  coverArt: _primaryImage(json) ?? (json['AlbumPrimaryImageTag'] == null ? null : json['AlbumId'] as String?),
  duration: _duration(json),
);

Artist _artist(Map<String, dynamic> json) => Artist(
  id: json['Id'] as String,
  name: json['Name'] as String? ?? '',
  coverArt: _primaryImage(json),
  albumCount: (json['AlbumCount'] as num?)?.toInt(),
);
