import 'package:flutter/material.dart';

import '../services.dart';
import '../subsonic/models.dart';
import 'album_page.dart';
import 'cover.dart';

/// The library's albums, newest first.
class AlbumsView extends StatefulWidget {
  const AlbumsView({super.key});

  @override
  State<AlbumsView> createState() => _AlbumsViewState();
}

class _AlbumsViewState extends State<AlbumsView> {
  Future<List<Album>>? _albums;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _albums ??= ServicesScope.of(context).api.albums();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: _albums,
    builder: (context, snapshot) {
      if (snapshot.hasError) return Center(child: Text('Não consegui listar os álbuns: ${snapshot.error}'));
      final albums = snapshot.data;
      if (albums == null) return const Center(child: CircularProgressIndicator());
      return RefreshIndicator(
        onRefresh: () async {
          final reload = ServicesScope.of(context).api.albums();
          setState(() => _albums = reload);
          await reload;
        },
        child: AlbumGrid(albums),
      );
    },
  );
}

/// Albums as a grid of covers, under an optional [header]. Each opens its page.
class AlbumGrid extends StatelessWidget {
  const AlbumGrid(this.albums, {this.header, this.subtitle, super.key});

  final List<Album> albums;
  final Widget? header;

  /// The line under each name; the artist, by default.
  final String Function(Album album)? subtitle;

  @override
  Widget build(BuildContext context) => CustomScrollView(
    slivers: [
      if (header != null) SliverToBoxAdapter(child: header),
      SliverPadding(
        padding: const EdgeInsets.all(16),
        sliver: SliverGrid.builder(
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 180,
            mainAxisSpacing: 16,
            crossAxisSpacing: 16,
            childAspectRatio: 0.75,
          ),
          itemCount: albums.length,
          itemBuilder: (context, i) =>
              _AlbumTile(albums[i], subtitle: subtitle?.call(albums[i]) ?? albums[i].artist ?? ''),
        ),
      ),
    ],
  );
}

class _AlbumTile extends StatelessWidget {
  const _AlbumTile(this.album, {required this.subtitle});

  final Album album;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => AlbumPage(album))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: ClipRRect(borderRadius: BorderRadius.circular(8), child: Cover(album.coverArt)),
          ),
          const SizedBox(height: 6),
          Text(album.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.titleSmall),
          Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.bodySmall),
        ],
      ),
    );
  }
}
