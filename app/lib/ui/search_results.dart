import 'package:flutter/material.dart';

import '../services.dart';
import '../subsonic/models.dart';
import 'album_page.dart';
import 'artist_page.dart';
import 'artists_view.dart';
import 'cover.dart';
import 'current_song.dart';
import 'errors.dart';
import 'now_playing_bar.dart';

/// What a search found: artists and albums, which open their page, and songs, which play.
class SearchResultsList extends StatelessWidget {
  const SearchResultsList(this.results, {super.key});

  final Future<SearchResults> results;

  static Future<void> _play(BuildContext context, List<Song> songs, int index) async {
    final messenger = ScaffoldMessenger.of(context);
    final result = await ServicesScope.of(context).connect.playSongs(songs, index);
    if (!result.ok) messenger.showSnackBar(SnackBar(content: Text(describeError(result.error))));
  }

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: results,
    builder: (context, snapshot) {
      if (snapshot.hasError) return Center(child: Text('Não consegui buscar: ${snapshot.error}'));
      final results = snapshot.data;
      if (results == null) return const Center(child: CircularProgressIndicator());
      final (:artists, :albums, :songs) = results;
      if (artists.isEmpty && albums.isEmpty && songs.isEmpty) return const Center(child: Text('Nada encontrado.'));
      return ListView(
        children: [
          if (artists.isNotEmpty) const _Heading('Artistas'),
          for (final artist in artists)
            ListTile(
              leading: _Thumbnail(artist.coverArt, round: true),
              title: Text(artist.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(albumCount(artist.albumCount)),
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ArtistPage(artist))),
            ),
          if (albums.isNotEmpty) const _Heading('Álbuns'),
          for (final album in albums)
            ListTile(
              leading: _Thumbnail(album.coverArt),
              title: Text(album.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                [album.artist, album.year].nonNulls.join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => AlbumPage(album))),
            ),
          if (songs.isNotEmpty) const _Heading('Músicas'),
          // As on the album page: the queue is the songs listed, from the one picked.
          for (final (i, song) in songs.indexed)
            CurrentSong(
              song,
              builder: (context, current, playing) => ListTile(
                selected: current,
                leading: _Thumbnail(song.coverArt, playing: playing),
                title: Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(
                  [song.artist, song.album].nonNulls.join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: Text(formatDuration(song.duration)),
                onTap: () => _play(context, songs, i),
              ),
            ),
        ],
      );
    },
  );
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Text(text, style: Theme.of(context).textTheme.titleMedium),
  );
}

class _Thumbnail extends StatelessWidget {
  const _Thumbnail(this.coverArt, {this.round = false, this.playing = false});

  final String? coverArt;

  /// An artist's: round, with a person for a placeholder.
  final bool round;

  /// A song's that plays: the equalizer goes over it, on a veil.
  final bool playing;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 48,
    child: round
        ? ClipOval(child: Cover(coverArt, size: 96, icon: Icons.person_outline))
        : ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Cover(coverArt, size: 96),
                // The primary color's light tone in either theme, which stands out on the dark veil.
                if (playing)
                  ColoredBox(
                    color: Colors.black54,
                    child: Icon(CurrentSong.icon, color: Theme.of(context).colorScheme.primaryFixedDim),
                  ),
              ],
            ),
          ),
  );
}
