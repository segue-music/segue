import 'dart:async';

import 'package:flutter/material.dart';

import '../server/models.dart';
import '../server/server.dart';
import '../services.dart';
import 'album_page.dart';
import 'cover.dart';
import 'focus_ring.dart';
import 'spinner.dart';

/// The library's albums, by name, a page at a time: the next as the grid nears its end.
class AlbumsView extends StatefulWidget {
  const AlbumsView({super.key});

  @override
  State<AlbumsView> createState() => _AlbumsViewState();
}

class _AlbumsViewState extends State<AlbumsView> {
  static const _pageSize = 200;

  /// How far from the end of the grid the next page is asked for.
  static const _ahead = 800.0;

  final _albums = <Album>[];
  bool _started = false;
  bool _loading = false;

  /// The server has no more.
  bool _done = false;

  /// Why the latest page didn't come. Only "Tentar de novo" asks for it again.
  Object? _error;

  /// Counts the starts over, so that a page asked for before one is dropped.
  int _generation = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    if (!_started) {
      _started = true;
      scheduleMicrotask(_load); // out of the build
    }
  }

  /// Asks for the next page; [over], for the first again, which replaces the albums when it comes.
  Future<void> _load({bool over = false}) async {
    if (!mounted || (!over && (_loading || _done || _error != null))) {
      return;
    }

    final generation = over ? ++_generation : _generation;
    final api = ServicesScope.of(context).api;
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final page = await api.albums(order: AlbumOrder.name, size: _pageSize, offset: over ? 0 : _albums.length);

      if (!mounted || generation != _generation) {
        return;
      }

      setState(() {
        if (over) {
          _albums.clear();
        }

        _albums.addAll(page);
        _done = page.length < _pageSize;
        _loading = false;
      });
    } on Object catch (error) {
      if (!mounted || generation != _generation) {
        return;
      }

      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  void _retry() {
    _error = null; // which keeps _load from asking by itself
    _load();
  }

  /// Asks for the next page when the grid nears its end: as it scrolls, and when it changes size.
  bool _scrolled(Notification notification) {
    final metrics = switch (notification) {
      ScrollNotification(:final metrics) || ScrollMetricsNotification(:final metrics) => metrics,
      _ => null,
    };

    if (metrics != null && metrics.extentAfter < _ahead && !_loading && !_done && _error == null) {
      scheduleMicrotask(_load); // notifications can come during layout
    }

    return false;
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;

    if (_albums.isEmpty) {
      if (error != null) {
        return Center(child: _Retry('Não consegui listar os álbuns: $error', onRetry: _retry));
      }

      if (!_done) {
        return const Center(child: Spinner());
      }
    }

    return NotificationListener<Notification>(
      onNotification: _scrolled,
      child: RefreshIndicator(
        onRefresh: () => _load(over: true),
        child: AlbumGrid(
          _albums,
          footer: error != null
              ? _Retry('Não consegui listar mais álbuns: $error', onRetry: _retry)
              : _loading
              ? const Padding(
                  padding: EdgeInsets.only(bottom: 16),
                  child: Center(child: Spinner()),
                )
              : null,
        ),
      ),
    );
  }
}

/// What went wrong, and a button to try again.
class _Retry extends StatelessWidget {
  const _Retry(this.message, {required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(message, textAlign: TextAlign.center),
        const SizedBox(height: 8),
        TextButton(onPressed: onRetry, child: const Text('Tentar de novo')),
      ],
    ),
  );
}

/// Albums as a grid of covers, between an optional [header] and [footer]. Each opens its page.
class AlbumGrid extends StatelessWidget {
  const AlbumGrid(this.albums, {this.header, this.footer, this.subtitle, super.key});

  final List<Album> albums;
  final Widget? header;
  final Widget? footer;

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
          itemBuilder: (context, i) => AlbumTile(albums[i], subtitle: subtitle?.call(albums[i])),
        ),
      ),
      if (footer != null) SliverToBoxAdapter(child: footer),
    ],
  );
}

/// An album's cover, with its name and a line under it. It opens the album's page.
class AlbumTile extends StatelessWidget {
  const AlbumTile(this.album, {this.subtitle, super.key});

  final Album album;

  /// The line under the name; the artist, by default.
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return FocusRing(
      child: InkWell(
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
            Text(subtitle ?? album.artist ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: text.bodySmall),
          ],
        ),
      ),
    );
  }
}
