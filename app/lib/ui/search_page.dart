import 'dart:async';

import 'package:flutter/material.dart';

import '../services.dart';
import '../subsonic/models.dart';
import 'album_page.dart';
import 'cover.dart';
import 'errors.dart';
import 'now_playing_bar.dart';

/// Albums and songs on the server, found as you type.
class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  /// How long typing has to stop before the search goes out, so that it isn't one per key.
  static const typingPause = Duration(milliseconds: 300);

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  Timer? _typing;
  String _query = '';
  Future<SearchResults>? _results;

  void _typed(String text) {
    _typing?.cancel();
    _typing = Timer(SearchPage.typingPause, () => _search(text));
  }

  void _search(String text) {
    _typing?.cancel();
    final query = text.trim();
    if (query == _query) return;
    setState(() {
      _query = query;
      _results = query.isEmpty ? null : ServicesScope.of(context).api.search(query);
    });
  }

  Future<void> _play(List<Song> songs, int index) async {
    final result = await ServicesScope.of(context).connect.playSongs(songs, index);
    if (!result.ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(describeError(result.error))));
    }
  }

  @override
  void dispose() {
    _typing?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(hintText: 'Álbum, artista ou música', border: InputBorder.none),
          onChanged: _typed,
          onSubmitted: _search,
        ),
      ),
      body: _results == null
          ? const SizedBox()
          : FutureBuilder(
              future: _results,
              builder: (context, snapshot) {
                if (snapshot.hasError) return Center(child: Text('Não consegui buscar: ${snapshot.error}'));
                final results = snapshot.data;
                if (results == null) return const Center(child: CircularProgressIndicator());
                final (:albums, :songs) = results;
                if (albums.isEmpty && songs.isEmpty) return const Center(child: Text('Nada encontrado.'));
                return ListView(
                  children: [
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
                        onTap: () =>
                            Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => AlbumPage(album))),
                      ),
                    if (songs.isNotEmpty) const _Heading('Músicas'),
                    // As on the album page: the queue is the songs listed, from the one picked.
                    for (final (i, song) in songs.indexed)
                      ListTile(
                        leading: _Thumbnail(song.coverArt),
                        title: Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          [song.artist, song.album].nonNulls.join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Text(formatDuration(song.duration)),
                        onTap: () => _play(songs, i),
                      ),
                  ],
                );
              },
            ),
      bottomNavigationBar: const NowPlayingBar(),
    );
  }
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
  const _Thumbnail(this.coverArt);

  final String? coverArt;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 48,
    child: ClipRRect(borderRadius: BorderRadius.circular(4), child: Cover(coverArt, size: 96)),
  );
}
