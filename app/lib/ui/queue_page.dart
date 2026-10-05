import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services.dart';
import 'cover.dart';
import 'player_controls.dart';

/// The queue of the device the app controls, in its play order (shuffled, or not): the current
/// track on top, the next ones under it, and what played before above it. A tap on a track plays it
/// there.
class QueuePage extends StatefulWidget {
  const QueuePage({super.key});

  static Future<void> open(BuildContext context) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const QueuePage()));

  @override
  State<QueuePage> createState() => _QueuePageState();
}

class _QueuePageState extends State<QueuePage> {
  /// The track on top: the current one when the page opened. It stays there as the music moves on,
  /// so that the list doesn't move under the finger.
  int? _top;
  final _fromTop = UniqueKey();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _top ??= ServicesScope.of(context).connect.queue.index;
  }

  @override
  Widget build(BuildContext context) {
    final connect = ServicesScope.of(context).connect;
    // On a TV the remote starts on the current track. Elsewhere the page itself takes the focus, so
    // that Esc closes it, and no track looks focused.
    final television = MediaQuery.navigationModeOf(context) == NavigationMode.directional;

    void close() => Navigator.of(context).maybePop();

    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): close},
      child: Focus(
        autofocus: !television,
        child: ListenableBuilder(
          listenable: connect,
          builder: (context, _) {
            final now = connect.nowPlaying;
            final (:tracks, :index) = connect.queue;
            final top = _top!.clamp(0, tracks.length);

            Widget tile(int i) {
              final track = tracks[i];
              final current = i == index;
              final about = [track.artist, track.album].nonNulls.join(' · ');
              final duration = track.durationMs;
              return ListTile(
                autofocus: current && television,
                selected: current,
                leading: Thumbnail(track.id, playing: current && (now?.playing ?? false)),
                title: Text(track.title ?? '', maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: about.isEmpty ? null : Text(about, maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: Text(formatDuration(duration == null ? null : Duration(milliseconds: duration))),
                onTap: now?.canJump ?? false ? () => runCommand(context, () => connect.jump(i)) : null,
              );
            }

            return Scaffold(
              appBar: AppBar(title: Text(now?.device == null ? 'Fila' : 'Fila em ${now!.device}')),
              body: tracks.isEmpty
                  ? const Center(child: Text('A fila está vazia.'))
                  // The list starts at the track on top; the ones before it go up from there.
                  : CustomScrollView(
                      center: _fromTop,
                      slivers: [
                        SliverList.builder(itemCount: top, itemBuilder: (_, i) => tile(top - 1 - i)),
                        SliverList.builder(
                          key: _fromTop,
                          itemCount: tracks.length - top,
                          itemBuilder: (_, i) => tile(top + i),
                        ),
                      ],
                    ),
            );
          },
        ),
      ),
    );
  }
}
