import 'package:flutter/material.dart';

import '../server/models.dart';
import '../services.dart';
import 'albums_view.dart';
import 'artists_view.dart';
import 'cover.dart';
import 'now_playing_bar.dart';
import 'spinner.dart';

/// An artist and their albums, newest first.
class ArtistPage extends StatefulWidget {
  const ArtistPage(this.artist, {super.key});

  final Artist artist;

  @override
  State<ArtistPage> createState() => _ArtistPageState();
}

class _ArtistPageState extends State<ArtistPage> {
  Future<(Artist, List<Album>)>? _artist;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _artist ??= ServicesScope.of(context).api.artist(widget.artist.id);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text(widget.artist.name)),
      body: FutureBuilder(
        future: _artist,
        builder: (context, snapshot) {
          if (snapshot.hasError) return Center(child: Text('Não consegui abrir o artista: ${snapshot.error}'));
          final data = snapshot.data;
          if (data == null) return const Center(child: Spinner());
          final (artist, albums) = data;
          final newestFirst = [...albums]..sort((a, b) => (b.year ?? 0).compareTo(a.year ?? 0));
          return AlbumGrid(
            newestFirst,
            subtitle: (album) => album.year?.toString() ?? '',
            header: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Row(
                children: [
                  SizedBox.square(
                    dimension: 140,
                    child: ClipOval(
                      child: Cover(artist.coverArt ?? widget.artist.coverArt, icon: Icons.person_outline),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(artist.name, style: text.titleLarge),
                        Text(albumCount(artist.albumCount ?? albums.length), style: text.bodyMedium),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
      bottomNavigationBar: const NowPlayingBar(),
    );
  }
}
