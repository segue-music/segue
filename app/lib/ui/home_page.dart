import 'package:flutter/material.dart';

import '../segue/client.dart';
import '../services.dart';
import '../subsonic/models.dart';
import 'album_page.dart';
import 'cover.dart';
import 'devices_sheet.dart';
import 'now_playing_bar.dart';

class HomePage extends StatefulWidget {
  const HomePage({required this.onSignOut, super.key});

  final VoidCallback onSignOut;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  Future<List<Album>>? _albums;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _albums ??= ServicesScope.of(context).api.albums();
  }

  @override
  Widget build(BuildContext context) {
    final services = ServicesScope.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Álbuns'),
        actions: [
          _HubStatus(client: services.connect.client),
          IconButton(tooltip: 'Aparelhos', icon: const Icon(Icons.devices), onPressed: () => showDevicesSheet(context)),
          IconButton(tooltip: 'Sair', icon: const Icon(Icons.logout), onPressed: widget.onSignOut),
        ],
      ),
      body: FutureBuilder(
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
        HubStatus.rejected => const Tooltip(message: 'O hub recusou este aparelho', child: Icon(Icons.error_outline)),
      },
    );
  }
}
