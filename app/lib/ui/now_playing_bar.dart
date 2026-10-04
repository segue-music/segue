import 'dart:async';

import 'package:flutter/material.dart';

import '../segue/protocol.dart';
import '../services.dart';
import 'cover.dart';
import 'devices_sheet.dart';
import 'errors.dart';

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

  /// Where the slider is held, in place of the position: while dragging, and after letting go
  /// until the position gets there (from another device, that comes with its next report).
  Duration? _held;
  bool _dragging = false;
  Timer? _letGo;

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
    _letGo?.cancel();
    super.dispose();
  }

  Future<void> _do(Future<Result> Function() action) async {
    final result = await action();
    if (!result.ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(describeError(result.error))));
    }
  }

  void _seekTo(Duration target) {
    setState(() {
      _dragging = false;
      _held = target;
    });
    _letGo?.cancel();
    _letGo = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _held = null);
    });
    unawaited(_do(() => ServicesScope.of(context).connect.seek(target)));
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
        final held = _held;
        if (held != null && !_dragging && (now.position - held).abs() < const Duration(seconds: 1)) {
          _held = null; // the position got there
        }
        final position = _held ?? now.position;
        final length = duration?.inMilliseconds ?? 0;
        return Material(
          color: colors.surfaceContainer,
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                  ),
                  child: Slider(
                    padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
                    max: length > 0 ? length.toDouble() : 1,
                    value: length > 0 ? position.inMilliseconds.clamp(0, length).toDouble() : 0,
                    semanticFormatterCallback: (ms) => formatDuration(Duration(milliseconds: ms.round())),
                    onChangeStart: length > 0 ? (_) => _dragging = true : null,
                    onChanged: length > 0 ? (ms) => setState(() => _held = Duration(milliseconds: ms.round())) : null,
                    onChangeEnd: length > 0 ? (ms) => _seekTo(Duration(milliseconds: ms.round())) : null,
                  ),
                ),
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
                            Text(now.artist ?? '', maxLines: 1, overflow: TextOverflow.ellipsis),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(formatDuration(position), style: Theme.of(context).textTheme.bodySmall),
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
        );
      },
    );
  }
}
