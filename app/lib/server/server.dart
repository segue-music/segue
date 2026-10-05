import 'dart:typed_data';

import '../segue/protocol.dart';
import 'models.dart';

/// How the app introduces itself, to the media server and to the hub.
const clientName = 'Segue';
const appVersion = '0.1.0';

/// What the app keeps of a sign-in, to talk to the media server again without the password.
abstract interface class Credentials {
  /// The user's name on the media server.
  String get username;
}

/// The media server refused a request, or answered with something the app can't use.
class ServerError implements Exception {
  const ServerError(this.message, {this.isAuth = false});

  final String message;

  /// The server doesn't take the credentials: a wrong user or password, or a sign-in it forgot.
  final bool isAuth;

  @override
  String toString() => message;
}

/// Orders the library's albums come in.
enum AlbumOrder {
  /// The latest added to the library first.
  latest,

  /// By name.
  name,
}

/// The media server, through the API it speaks: `SubsonicApi` or `JellyfinApi`.
abstract interface class MediaServer {
  /// Also the API of the ids the hub gives this device (SPEC.md, section 8).
  Api get api;

  Credentials get credentials;

  /// The same credentials, for the hub's hello (SPEC.md, section 2).
  Auth get auth;

  /// Albums, in [order].
  Future<List<Album>> albums({required AlbumOrder order, int size = 100, int offset = 0});

  /// The albums the user plays most, the most played first; none before anything has played.
  Future<List<Album>> mostPlayedAlbums({int size = 20});

  /// An album and its songs, in order.
  Future<(Album, List<Song>)> album(String id);

  /// A song, with its album's and its artist's ids.
  Future<Song> song(String id);

  /// Artists, albums and songs whose name, title or artist matches [query].
  Future<SearchResults> search(String query, {int artists = 5, int albums = 10, int songs = 50});

  /// Every artist, by name.
  Future<List<Artist>> artists();

  /// An artist and their albums.
  Future<(Artist, List<Album>)> artist(String id);

  /// Where a song's audio is, for the player: the URL carries the credentials.
  Uri streamUrl(String songId);

  Uri coverArtUrl(String id, {int size = 300});

  /// The cover's image bytes.
  Future<Uint8List> coverArt(String id, {int size = 300});

  /// Ends the sign-in on the server, where it keeps one (Jellyfin). Never throws: signing out
  /// offline still signs out.
  Future<void> signOut();

  void close();
}
