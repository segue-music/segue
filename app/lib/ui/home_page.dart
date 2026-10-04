import 'dart:async';

import 'package:flutter/material.dart';

import '../segue/client.dart';
import '../segue/protocol.dart';
import '../services.dart';
import '../subsonic/models.dart';
import 'album_page.dart';
import 'cover.dart';
import 'devices_sheet.dart';
import 'now_playing_bar.dart';
import 'search_results.dart';

class HomePage extends StatefulWidget {
  const HomePage({required this.onSignOut, super.key});

  final VoidCallback onSignOut;

  /// How long typing in the search bar has to stop before the search goes out, so that it isn't one
  /// per key.
  static const searchTypingPause = Duration(milliseconds: 300);

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  Future<List<Album>>? _albums;
  final _search = TextEditingController();
  Timer? _typing;
  String _query = '';

  /// What the search bar found; null shows the albums.
  Future<SearchResults>? _results;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _albums ??= ServicesScope.of(context).api.albums();
  }

  void _typed(String text) {
    _typing?.cancel();
    _typing = Timer(HomePage.searchTypingPause, () => _searchFor(text));
  }

  void _searchFor(String text) {
    _typing?.cancel();
    final query = text.trim();
    if (query == _query) return;
    setState(() {
      _query = query;
      _results = query.isEmpty ? null : ServicesScope.of(context).api.search(query);
    });
  }

  void _clearSearch() {
    _search.clear();
    _searchFor('');
  }

  @override
  void dispose() {
    _typing?.cancel();
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final services = ServicesScope.of(context);
    final results = _results;
    final searchBar = SearchBar(
      controller: _search,
      hintText: 'Buscar álbum, artista ou música',
      leading: const Icon(Icons.search),
      trailing: [
        ListenableBuilder(
          listenable: _search,
          builder: (context, _) => _search.text.isEmpty
              ? const SizedBox.shrink()
              : IconButton(tooltip: 'Limpar', icon: const Icon(Icons.close), onPressed: _clearSearch),
        ),
      ],
      elevation: const WidgetStatePropertyAll(0),
      constraints: const BoxConstraints(maxWidth: 600, minHeight: 44, maxHeight: 44),
      textInputAction: TextInputAction.search,
      onChanged: _typed,
      onSubmitted: _searchFor,
    );
    // Next to the title when there is room for both; on a phone, on a line of its own under it.
    final narrow = MediaQuery.sizeOf(context).width < 600;
    return Scaffold(
      appBar: AppBar(
        title: narrow
            ? const Text('Álbuns')
            : Row(
                children: [
                  const Text('Álbuns'),
                  const SizedBox(width: 24),
                  Flexible(child: searchBar),
                ],
              ),
        bottom: narrow
            ? PreferredSize(
                preferredSize: const Size.fromHeight(56),
                child: Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 12), child: searchBar),
              )
            : null,
        actions: [
          _HubStatus(client: services.connect.client),
          IconButton(tooltip: 'Aparelhos', icon: const Icon(Icons.devices), onPressed: () => showDevicesSheet(context)),
          IconButton(tooltip: 'Sair', icon: const Icon(Icons.logout), onPressed: widget.onSignOut),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Kept underneath while searching, so that clearing the search goes back to the same place.
          Offstage(
            offstage: results != null,
            child: FutureBuilder(
              future: _albums,
              builder: (context, snapshot) {
                if (snapshot.hasError) return Center(child: Text('Não consegui listar os álbuns: ${snapshot.error}'));
                final albums = snapshot.data;
                if (albums == null) return const Center(child: CircularProgressIndicator());
                return RefreshIndicator(
                  onRefresh: () async {
                    final reload = services.api.albums();
                    setState(() => _albums = reload);
                    await reload;
                  },
                  child: GridView.builder(
                    padding: const EdgeInsets.all(16),
                    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 180,
                      mainAxisSpacing: 16,
                      crossAxisSpacing: 16,
                      childAspectRatio: 0.75,
                    ),
                    itemCount: albums.length,
                    itemBuilder: (context, i) => _AlbumTile(albums[i]),
                  ),
                );
              },
            ),
          ),
          if (results != null) SearchResultsList(results),
        ],
      ),
      bottomNavigationBar: const NowPlayingBar(),
    );
  }
}

class _AlbumTile extends StatelessWidget {
  const _AlbumTile(this.album);

  final Album album;

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
          Text(album.artist ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: text.bodySmall),
        ],
      ),
    );
  }
}

/// Whether Connect works: the hub's connection, at a glance.
class _HubStatus extends StatelessWidget {
  const _HubStatus({required this.client});

  final SegueClient? client;

  @override
  Widget build(BuildContext context) {
    final client = this.client;
    if (client == null) {
      return const Tooltip(message: 'Sem hub: só toca neste aparelho', child: Icon(Icons.cloud_off));
    }
    return ListenableBuilder(
      listenable: client,
      builder: (context, _) => switch (client.status) {
        HubStatus.connected => const Tooltip(message: 'Conectado ao hub', child: Icon(Icons.cloud_done)),
        HubStatus.connecting => const Tooltip(message: 'Conectando ao hub…', child: Icon(Icons.cloud_sync)),
        HubStatus.offline => const Tooltip(message: 'Hub fora do ar; tentando de novo', child: Icon(Icons.cloud_off)),
        HubStatus.rejected => Tooltip(
          message: client.lastClose?.code == CloseCode.replaced
              ? 'Este aparelho se conectou de novo em outro lugar (outra cópia do app aberta?)'
              : 'O hub recusou este aparelho',
          child: const Icon(Icons.error_outline),
        ),
      },
    );
  }
}
