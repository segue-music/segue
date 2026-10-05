import 'package:flutter/material.dart';

import '../server/models.dart';
import '../services.dart';
import 'artist_page.dart';
import 'cover.dart';
import 'focus_ring.dart';
import 'spinner.dart';

/// "1 álbum", "5 álbuns"; empty when the server didn't say.
String albumCount(int? count) => switch (count) {
  null => '',
  1 => '1 álbum',
  _ => '$count álbuns',
};

/// The library's artists, by name.
class ArtistsView extends StatefulWidget {
  const ArtistsView({super.key});

  @override
  State<ArtistsView> createState() => _ArtistsViewState();
}

class _ArtistsViewState extends State<ArtistsView> {
  Future<List<Artist>>? _artists;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _artists ??= ServicesScope.of(context).api.artists();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: _artists,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return Center(child: Text('Não consegui listar os artistas: ${snapshot.error}'));
      }

      final artists = snapshot.data;

      if (artists == null) {
        return const Center(child: Spinner());
      }

      return RefreshIndicator(
        onRefresh: () async {
          final reload = ServicesScope.of(context).api.artists();
          setState(() => _artists = reload);
          await reload;
        },
        child: GridView.builder(
          padding: const EdgeInsets.all(16),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 180,
            mainAxisSpacing: 16,
            crossAxisSpacing: 16,
            childAspectRatio: 0.72,
          ),
          itemCount: artists.length,
          itemBuilder: (context, i) => _ArtistTile(artists[i]),
        ),
      );
    },
  );
}

class _ArtistTile extends StatelessWidget {
  const _ArtistTile(this.artist);

  final Artist artist;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return FocusRing(
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ArtistPage(artist))),
        child: Column(
          children: [
            AspectRatio(
              aspectRatio: 1,
              child: ClipOval(child: Cover(artist.coverArt, icon: Icons.person_outline)),
            ),
            const SizedBox(height: 6),
            Text(artist.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.titleSmall),
            Text(albumCount(artist.albumCount), maxLines: 1, style: text.bodySmall),
          ],
        ),
      ),
    );
  }
}
