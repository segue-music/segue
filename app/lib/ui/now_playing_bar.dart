import 'package:flutter/material.dart';

import 'cover.dart';
import 'devices_sheet.dart';
import 'focus_ring.dart';
import 'player_controls.dart';
import 'player_page.dart';

export 'player_controls.dart' show formatDuration;

/// What plays, wherever it plays, with the controls and the device picker. The song opens the
/// full-screen player.
class NowPlayingBar extends StatelessWidget {
  const NowPlayingBar({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // Shuffle and repeat need room; a phone-sized bar has none (they are in the full-screen player).
    final wide = MediaQuery.sizeOf(context).width >= 600;
    return NowPlayingBuilder(
      builder: (context, connect, now) {
        if (now == null) return const SizedBox.shrink();
        return Material(
          color: colors.surfaceContainer,
          child: SafeArea(
            top: false,
            child: FocusTraversalGroup(
              policy: _BarTraversalPolicy.instance,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(padding: const EdgeInsets.fromLTRB(4, 4, 4, 0), child: SeekSlider(now)),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
                    child: Row(
                      children: [
                        Expanded(
                          child: Tooltip(
                            message: 'Abrir o player',
                            child: FocusRing(
                              borderRadius: BorderRadius.circular(4),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(4),
                                onTap: () => PlayerPage.open(context),
                                child: Row(
                                  children: [
                                    SizedBox.square(
                                      dimension: 48,
                                      child: ClipRRect(
                                        borderRadius: BorderRadius.circular(4),
                                        child: Cover(now.coverArt, size: 96),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            now.title ?? 'Nada tocando',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                          Text(now.artist ?? '', maxLines: 1, overflow: TextOverflow.ellipsis),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                        if (wide) ShuffleButton(now),
                        IconButton(
                          tooltip: 'Anterior',
                          icon: const Icon(Icons.skip_previous),
                          onPressed: () => runCommand(context, connect.previous),
                        ),
                        IconButton(
                          tooltip: now.playing ? 'Pausar' : 'Tocar',
                          icon: Icon(now.playing ? Icons.pause : Icons.play_arrow),
                          onPressed: () => runCommand(context, connect.toggle),
                        ),
                        IconButton(
                          tooltip: 'Próxima',
                          icon: const Icon(Icons.skip_next),
                          onPressed: () => runCommand(context, connect.next),
                        ),
                        if (wide) RepeatButton(now),
                        IconButton(
                          tooltip: 'Aparelhos',
                          icon: Icon(Icons.devices, color: now.device == null ? null : colors.primary),
                          onPressed: () => showDevicesSheet(context),
                        ),
                      ],
                    ),
                  ),
                  // Where it plays, when that's another device, as Spotify's strip under the player.
                  if (now.device != null)
                    Container(
                      width: double.infinity,
                      color: colors.primaryContainer,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      child: Row(
                        children: [
                          Icon(Icons.speaker, size: 16, color: colors.onPrimaryContainer),
                          const SizedBox(width: 6),
                          Text(
                            '${now.playing ? 'Tocando' : 'Pausado'} em ${now.device}',
                            style: TextStyle(color: colors.onPrimaryContainer, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Moving around the bar with the arrows (a TV remote's): left and right along its row of buttons,
/// up and down between that row and the slider, up from the slider out of the bar, and nowhere past
/// its ends. Flutter's own directional search looks at the whole screen, where the album grid's rows
/// built past the bottom of the screen lie under the bar, level with its buttons, and could win.
class _BarTraversalPolicy extends ReadingOrderTraversalPolicy {
  _BarTraversalPolicy._();

  static final instance = _BarTraversalPolicy._();

  @override
  bool inDirection(FocusNode currentNode, TraversalDirection direction) {
    final here = currentNode.rect;
    final bar = [
      for (final node in currentNode.nearestScope!.traversalDescendants)
        if (node != currentNode && FocusTraversalGroup.maybeOfNode(node) == this) node,
    ];
    bool level(FocusNode node) => node.rect.top < here.bottom && node.rect.bottom > here.top;
    double away(FocusNode node) => (node.rect.center - here.center).distance;
    FocusNode? closest(Iterable<FocusNode> nodes) =>
        nodes.isEmpty ? null : nodes.reduce((a, b) => away(a) <= away(b) ? a : b);
    final target = closest(switch (direction) {
      TraversalDirection.left => bar.where((node) => level(node) && node.rect.center.dx < here.center.dx),
      TraversalDirection.right => bar.where((node) => level(node) && node.rect.center.dx > here.center.dx),
      TraversalDirection.up => bar.where((node) => node.rect.bottom <= here.top + 1),
      TraversalDirection.down => bar.where((node) => node.rect.top >= here.bottom - 1),
    });
    if (target != null) {
      requestFocusCallback(target);
      return true;
    }
    // From the top of the bar, up goes on as anywhere else; past its other edges, nowhere.
    return direction == TraversalDirection.up && super.inDirection(currentNode, direction);
  }
}
