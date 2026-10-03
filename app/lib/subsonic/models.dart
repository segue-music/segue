import '../segue/protocol.dart';

class Album {
  const Album({required this.id, required this.name, this.artist, this.coverArt, this.year, this.songCount});

  factory Album.fromJson(Map<String, dynamic> json) => Album(
    id: json['id'] as String,
    name: json['name'] as String? ?? '',
    artist: json['artist'] as String?,
    coverArt: json['coverArt'] as String?,
    year: (json['year'] as num?)?.toInt(),
    songCount: (json['songCount'] as num?)?.toInt(),
  );

  final String id;
  final String name;
  final String? artist;
  final String? coverArt;
  final int? year;
  final int? songCount;
}

class Song {
  const Song({required this.id, required this.title, this.artist, this.album, this.coverArt, this.duration});

  factory Song.fromJson(Map<String, dynamic> json) => Song(
    id: json['id'] as String,
    title: json['title'] as String? ?? '',
    artist: json['artist'] as String?,
    album: json['album'] as String?,
    coverArt: json['coverArt'] as String?,
    duration: json['duration'] == null ? null : Duration(seconds: (json['duration'] as num).toInt()),
  );

  /// A song another device sent, by its Subsonic id. The cover goes by the song id: Navidrome takes
  /// a raw entity id for getCoverArt (parseArtworkID in core/artwork/artwork.go).
  factory Song.fromQueueItem(QueueItem item) => Song(
    id: item.id!,
    title: item.title ?? '',
    artist: item.artist,
    album: item.album,
    coverArt: item.id,
    duration: item.durationMs == null ? null : Duration(milliseconds: item.durationMs!),
  );

  final String id;
  final String title;
  final String? artist;
  final String? album;
  final String? coverArt;
  final Duration? duration;

  QueueItem toQueueItem() =>
      QueueItem(id: id, title: title, artist: artist, album: album, durationMs: duration?.inMilliseconds);
}
