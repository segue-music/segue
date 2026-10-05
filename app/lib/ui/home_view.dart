import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../server/models.dart';
import '../server/server.dart';
import '../services.dart';
import 'albums_view.dart';
import 'spinner.dart';

/// How many albums a row shows at most.
const _limit = 20;

/// The first section: the albums the user plays most, and the latest added to the library, each in a
/// row that scrolls sideways.
class HomeView extends StatefulWidget {
  const HomeView({super.key});

  @override
  State<HomeView> createState() => _HomeViewState();
}

class _HomeViewState extends State<HomeView> {
  late Future<List<Album>> _mostPlayed;
  late Future<List<Album>> _latest;
  bool _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loaded) _load();
  }

  void _load() {
    final api = ServicesScope.of(context).api;
    _mostPlayed = api.mostPlayedAlbums(size: _limit);
    _latest = api.albums(order: AlbumOrder.latest, size: _limit);
    _loaded = true;
  }

  @override
  Widget build(BuildContext context) => RefreshIndicator(
    onRefresh: () async {
      setState(_load);
      // Each row shows its own failure.
      await Future.wait([_mostPlayed, _latest]).catchError((_) => const <List<Album>>[]);
    },
    child: ListView(
      padding: const EdgeInsets.only(bottom: 16),
      children: [
        _AlbumRow(title: 'Mais tocados', albums: _mostPlayed, empty: 'Os álbuns que você mais ouvir aparecem aqui.'),
        _AlbumRow(title: 'Adicionados recentemente', albums: _latest, empty: 'A biblioteca está vazia.'),
      ],
    ),
  );
}

/// A titled row of albums, which scrolls sideways: by the arrows in its right corner, or dragged.
class _AlbumRow extends StatefulWidget {
  const _AlbumRow({required this.title, required this.albums, required this.empty});

  final String title;
  final Future<List<Album>> albums;

  /// What the row says when there are none.
  final String empty;

  static const _tileWidth = 160.0;
  static const _gap = 16.0;

  /// As tall as a tile of the album grid this wide.
  static const _height = _tileWidth / 0.75;

  @override
  State<_AlbumRow> createState() => _AlbumRowState();
}

class _AlbumRowState extends State<_AlbumRow> {
  final _scroll = ScrollController();

  /// The row's latest size and length, which change without scrolling it: once it is first laid out,
  /// and when the window changes.
  final _metrics = ValueNotifier<ScrollMetrics?>(null);

  @override
  void dispose() {
    _scroll.dispose();
    _metrics.dispose();
    super.dispose();
  }

  /// Scrolls a screenful of albums forward (1) or back (-1), with an album at the left edge.
  void _page(int direction) {
    final position = _scroll.position;
    const stride = _AlbumRow._tileWidth + _AlbumRow._gap;
    final perScreen = max(1, ((position.viewportDimension - _AlbumRow._gap) / stride).floor());
    // A bit of slack, so that an album a hair off the edge still counts as at it.
    final at = position.pixels / stride;
    final album = direction > 0 ? (at + 0.01).floor() + perScreen : (at - 0.01).ceil() - perScreen;
    _scroll.animateTo(
      (album * stride).clamp(position.minScrollExtent, position.maxScrollExtent),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    Widget note(String message) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Text(message, style: text.bodyMedium),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
          child: SizedBox(
            height: 48, // the arrows' height, also without them
            child: Row(
              children: [
                Expanded(child: Text(widget.title, style: text.titleLarge)),
                _arrows(),
              ],
            ),
          ),
        ),
        FutureBuilder(
          future: widget.albums,
          builder: (context, snapshot) {
            if (snapshot.hasError) return note('Não consegui listar os álbuns: ${snapshot.error}');
            final albums = snapshot.data;
            if (albums == null) {
              return const SizedBox(
                height: _AlbumRow._height,
                child: Center(child: Spinner()),
              );
            }
            if (albums.isEmpty) return note(widget.empty);
            // Also from a server that sends more than it was asked for.
            return SizedBox(height: _AlbumRow._height, child: _strip(albums.take(_limit).toList()));
          },
        ),
      ],
    );
  }

  /// Back and forward, each while there are albums that way; none when they all fit. Out of the
  /// focus's way: the keyboard and the remote go along the albums themselves.
  Widget _arrows() => ListenableBuilder(
    listenable: Listenable.merge([_scroll, _metrics]),
    builder: (context, _) {
      if (!_scroll.hasClients) return const SizedBox.shrink();
      final position = _scroll.position;
      if (!position.hasContentDimensions || position.maxScrollExtent <= position.minScrollExtent) {
        return const SizedBox.shrink();
      }
      return ExcludeFocus(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Voltar',
              icon: const Icon(Icons.chevron_left),
              onPressed: position.extentBefore > 0 ? () => _page(-1) : null,
            ),
            IconButton(
              tooltip: 'Avançar',
              icon: const Icon(Icons.chevron_right),
              onPressed: position.extentAfter > 0 ? () => _page(1) : null,
            ),
          ],
        ),
      );
    },
  );

  Widget _strip(List<Album> albums) => NotificationListener<ScrollMetricsNotification>(
    onNotification: (notification) {
      _metrics.value = notification.metrics;
      return false;
    },
    child: ScrollConfiguration(
      // No scrollbar, which desktops add by themselves: the arrows take its place. Dragged with a
      // mouse too: a vertical wheel scrolls the page, not the row.
      behavior: ScrollConfiguration.of(context)
          .copyWith(scrollbars: false, dragDevices: PointerDeviceKind.values.toSet()),
      child: ListView.separated(
        controller: _scroll,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: _AlbumRow._gap),
        itemCount: albums.length,
        separatorBuilder: (_, _) => const SizedBox(width: _AlbumRow._gap),
        itemBuilder: (context, i) => SizedBox(width: _AlbumRow._tileWidth, child: AlbumTile(albums[i])),
      ),
    ),
  );
}
