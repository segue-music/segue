import 'package:flutter/material.dart';

import '../services.dart';
import '../subsonic/models.dart';
import 'cover.dart';
import 'now_playing_bar.dart';

class AlbumPage extends StatefulWidget {
  const AlbumPage(this.album, {super.key});

  final Album album;

  @override
  State<AlbumPage> createState() => _AlbumPageState();
}

class _AlbumPageState extends State<AlbumPage> {
  Future<(Album, List<Song>)>? _album;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _album ??= ServicesScope.of(context).api.album(widget.album.id);
  }

  Future<void> _play(List<Song> songs, int index) async {
    final result = await ServicesScope.of(context).connect.playSongs(songs, index);
    if (!result.ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Não deu para tocar: ${result.error}')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text(widget.album.name)),
      body: FutureBuilder(
        future: _album,
        builder: (context, snapshot) {
          if (snapshot.hasError) return Center(child: Text('Não consegui abrir o álbum: ${snapshot.error}'));
          final data = snapshot.data;
          if (data == null) return const Center(child: CircularProgressIndicator());
          final (album, songs) = data;
          return ListView(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    SizedBox.square(
                      dimension: 140,
                      child: ClipRRect(borderRadius: BorderRadius.circular(8), child: Cover(album.coverArt)),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(album.name, style: text.titleLarge),
                          Text([album.artist, album.year].nonNulls.join(' · '), style: text.bodyMedium),
                          const SizedBox(height: 12),
                          FilledButton.icon(
                            onPressed: songs.isEmpty ? null : () => _play(songs, 0),
                            icon: const Icon(Icons.play_arrow),
                            label: const Text('Tocar'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              for (final (i, song) in songs.indexed)
                ListTile(
                  leading: SizedBox(width: 24, child: Text('${i + 1}', textAlign: TextAlign.end)),
                  title: Text(song.title),
                  subtitle: song.artist == album.artist ? null : Text(song.artist ?? ''),
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
