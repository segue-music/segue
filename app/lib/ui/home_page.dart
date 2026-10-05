import 'dart:async';

import 'package:flutter/material.dart';

import '../segue/client.dart';
import '../segue/protocol.dart';
import '../server/models.dart';
import '../services.dart';
import 'albums_view.dart';
import 'artists_view.dart';
import 'devices_sheet.dart';
import 'home_view.dart';
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

/// The library's sections, in the side rail (or, on a phone, the bar at the bottom).
enum _Section {
  home('Início', Icons.home_outlined, Icons.home),
  albums('Álbuns', Icons.album_outlined, Icons.album),
  artists('Artistas', Icons.person_outline, Icons.person);

  const _Section(this.label, this.icon, this.selectedIcon);

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

class _HomePageState extends State<HomePage> {
  final _search = TextEditingController();
  Timer? _typing;
  String _query = '';

  /// What the search bar found; null shows the section.
  Future<SearchResults>? _results;

  _Section _section = _Section.home;

  /// The sections opened so far: each loads the first time it is opened.
  final _opened = {_Section.home};

  void _select(int index) {
    final section = _Section.values[index];
    setState(() {
      _section = section;
      _opened.add(section);
    });

    if (_results != null) {
      _clearSearch();
    }
  }

  void _typed(String text) {
    _typing?.cancel();
    _typing = Timer(HomePage.searchTypingPause, () => _searchFor(text));
  }

  void _searchFor(String text) {
    _typing?.cancel();
    final query = text.trim();

    if (query == _query) {
      return;
    }

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
    final sections = Stack(
      fit: StackFit.expand,
      children: [
        // Each section stays underneath once opened, also while searching: going back to it, or
        // clearing the search, finds it where it was.
        for (final section in _opened)
          Offstage(
            key: ValueKey(section),
            offstage: results != null || section != _section,
            child: switch (section) {
              _Section.home => const HomeView(),
              _Section.albums => const AlbumsView(),
              _Section.artists => const ArtistsView(),
            },
          ),
        if (results != null) SearchResultsList(results),
      ],
    );
    return Scaffold(
      appBar: AppBar(
        title: narrow
            ? Text(_section.label)
            : Row(
                children: [
                  Text(_section.label),
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
      body: narrow
          ? sections
          : Row(
              children: [
                NavigationRail(
                  selectedIndex: _section.index,
                  onDestinationSelected: _select,
                  labelType: NavigationRailLabelType.all,
                  destinations: [
                    for (final section in _Section.values)
                      NavigationRailDestination(
                        icon: Icon(section.icon),
                        selectedIcon: Icon(section.selectedIcon),
                        label: Text(section.label),
                      ),
                  ],
                ),
                const VerticalDivider(width: 1),
                Expanded(child: sections),
              ],
            ),
      bottomNavigationBar: narrow
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const NowPlayingBar(),
                NavigationBar(
                  selectedIndex: _section.index,
                  onDestinationSelected: _select,
                  destinations: [
                    for (final section in _Section.values)
                      NavigationDestination(
                        icon: Icon(section.icon),
                        selectedIcon: Icon(section.selectedIcon),
                        label: section.label,
                      ),
                  ],
                ),
              ],
            )
          : const NowPlayingBar(),
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
