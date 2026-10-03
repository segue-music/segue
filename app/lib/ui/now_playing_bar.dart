import 'dart:async';

import 'package:flutter/material.dart';

import '../segue/protocol.dart';
import '../services.dart';
import 'cover.dart';
import 'devices_sheet.dart';

String formatDuration(Duration? duration) {
  if (duration == null) return '';
  final seconds = duration.inSeconds;
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}

/// What plays, wherever it plays, with the controls and the device picker.
class NowPlayingBar extends StatefulWidget {
  const NowPlayingBar({super.key});

  @override
  State<NowPlayingBar> createState() => _NowPlayingBarState();
}

class _NowPlayingBarState extends State<NowPlayingBar> {
  late final Timer _tick;

  @override
  void initState() {
    super.initState();
    // Positions move without events (here or on another device), so redraw while playing.
    _tick = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted && (ServicesScope.of(context).connect.nowPlaying?.playing ?? false)) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick.cancel();
    super.dispose();
  }

  Future<void> _do(Future<Result> Function() action) async {
    final result = await action();
    if (!result.ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Não deu: ${result.error}')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final connect = ServicesScope.of(context).connect;
    final colors = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: connect,
      builder: (context, _) {
        final now = connect.nowPlaying;
        if (now == null) return const SizedBox.shrink();
        final duration = now.duration;
        final progress = duration == null || duration == Duration.zero
            ? 0.0
            : (now.position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
        return Material(
          color: colors.surfaceContainer,
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                LinearProgressIndicator(value: progress, minHeight: 2),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  child: Row(
                    children: [
                      SizedBox.square(
                        dimension: 48,
                        child: ClipRRect(borderRadius: BorderRadius.circular(4), child: Cover(now.coverArt, size: 96)),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(now.title ?? 'Nada tocando', maxLines: 1, overflow: TextOverflow.ellipsis),
                            Text(
                              now.device == null ? (now.artist ?? '') : 'Tocando em ${now.device}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: now.device == null ? null : colors.primary),
                            ),
                          ],
                        ),
                      ),
                      Text(formatDuration(now.position), style: Theme.of(context).textTheme.bodySmall),
                      IconButton(
                        tooltip: 'Anterior',
                        icon: const Icon(Icons.skip_previous),
                        onPressed: () => _do(connect.previous),
                      ),
                      IconButton(
                        tooltip: now.playing ? 'Pausar' : 'Tocar',
                        icon: Icon(now.playing ? Icons.pause : Icons.play_arrow),
                        onPressed: () => _do(connect.toggle),
                      ),
                      IconButton(
                        tooltip: 'Próxima',
                        icon: const Icon(Icons.skip_next),
                        onPressed: () => _do(connect.next),
                      ),
                      IconButton(
                        tooltip: 'Aparelhos',
                        icon: Icon(Icons.devices, color: now.device == null ? null : colors.primary),
                        onPressed: () => showDevicesSheet(context),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
