import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../connect/connect.dart';
import 'cover.dart';
import 'devices_sheet.dart';
import 'player_controls.dart';
import 'queue_page.dart';

/// The full-screen player: what plays, wherever it plays, big, with every control.
class PlayerPage extends StatelessWidget {
  const PlayerPage({super.key});

  /// Slides it up over the current page.
  static Future<void> open(BuildContext context) => Navigator.of(context).push(
    PageRouteBuilder<void>(
      pageBuilder: (_, _, _) => const PlayerPage(),
      transitionsBuilder: (_, animation, _, child) => SlideTransition(
        position: Tween(
          begin: const Offset(0, 1),
          end: Offset.zero,
        ).chain(CurveTween(curve: Curves.easeOutCubic)).animate(animation),
        child: child,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    void close() => Navigator.of(context).maybePop();
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): close},
      child: Focus(
        autofocus: true,
        child: NowPlayingBuilder(
          builder: (context, connect, now) {
            final colors = Theme.of(context).colorScheme;
            final device = now?.device;
            return Scaffold(
              appBar: AppBar(
                leading: IconButton(tooltip: 'Fechar', icon: const Icon(Icons.keyboard_arrow_down), onPressed: close),
                centerTitle: true,
                title: device == null
                    ? null
                    : Text(
                        '${now!.playing ? 'Tocando' : 'Pausado'} em $device',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                actions: [
                  IconButton(
                    tooltip: 'Fila',
                    icon: const Icon(Icons.queue_music),
                    onPressed: () => QueuePage.open(context),
                  ),
                  IconButton(
                    tooltip: 'Aparelhos',
                    icon: Icon(Icons.devices, color: device == null ? null : colors.primary),
                    onPressed: () => showDevicesSheet(context),
                  ),
                ],
              ),
              body: now == null ? const Center(child: Text('Nada tocando')) : _Player(now, connect),
            );
          },
        ),
      ),
    );
  }
}

class _Player extends StatelessWidget {
  const _Player(this.now, this.connect);

  final NowPlaying now;
  final ConnectController connect;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return LayoutBuilder(
      builder: (context, box) {
        // The cover as big as it fits, leaving room for the rest under it.
        final side = min(box.maxWidth - 48, box.maxHeight - 260).clamp(96.0, 520.0);
        return SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
          child: Center(
            child: SizedBox(
              width: max(side, 280),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: SizedBox.square(
                      dimension: side,
                      child: ClipRRect(borderRadius: BorderRadius.circular(12), child: Cover(now.coverArt, size: 800)),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    now.title ?? 'Nada tocando',
                    style: text.headlineSmall,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    now.artist ?? '',
                    style: text.titleMedium?.copyWith(color: muted),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (now.album case final album?)
                    Text(
                      album,
                      style: text.bodyMedium?.copyWith(color: muted),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  const SizedBox(height: 12),
                  SeekSlider(now, timesBelow: true),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      ShuffleButton(now),
                      IconButton(
                        tooltip: 'Anterior',
                        iconSize: 36,
                        icon: const Icon(Icons.skip_previous),
                        onPressed: () => runCommand(context, connect.previous),
                      ),
                      IconButton.filled(
                        tooltip: now.playing ? 'Pausar' : 'Tocar',
                        iconSize: 40,
                        padding: const EdgeInsets.all(14),
                        icon: Icon(now.playing ? Icons.pause : Icons.play_arrow),
                        onPressed: () => runCommand(context, connect.toggle),
                      ),
                      IconButton(
                        tooltip: 'Próxima',
                        iconSize: 36,
                        icon: const Icon(Icons.skip_next),
                        onPressed: () => runCommand(context, connect.next),
                      ),
                      RepeatButton(now),
                    ],
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
