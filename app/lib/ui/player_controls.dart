import 'dart:async';

import 'package:flutter/material.dart';

import '../connect/connect.dart';
import '../segue/protocol.dart';
import '../services.dart';
import 'errors.dart';

/// The pieces the player bar and the full-screen player share.

String formatDuration(Duration? duration) {
  if (duration == null) {
    return '';
  }

  final seconds = duration.inSeconds;
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}

/// Runs a playback command and, if it fails, says why.
Future<void> runCommand(BuildContext context, Future<Result> Function() command) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final result = await command();

  if (!result.ok) {
    messenger?.showSnackBar(SnackBar(content: Text(describeError(result.error))));
  }
}

/// Builds with what plays, wherever it plays: on every change, and twice a second while it plays,
/// since positions move without events (here or on another device).
class NowPlayingBuilder extends StatefulWidget {
  const NowPlayingBuilder({required this.builder, super.key});

  final Widget Function(BuildContext context, ConnectController connect, NowPlaying? now) builder;

  @override
  State<NowPlayingBuilder> createState() => _NowPlayingBuilderState();
}

class _NowPlayingBuilderState extends State<NowPlayingBuilder> {
  late final Timer _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted && (ServicesScope.of(context).connect.nowPlaying?.playing ?? false)) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _tick.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final connect = ServicesScope.of(context).connect;
    return ListenableBuilder(
      listenable: connect,
      builder: (context, _) => widget.builder(context, connect, connect.nowPlaying),
    );
  }
}

/// Where the song is and how long it lasts, on a slider that jumps to where it is tapped, or to
/// where a drag lets go.
class SeekSlider extends StatefulWidget {
  const SeekSlider(this.now, {this.timesBelow = false, super.key});

  final NowPlaying now;

  /// The times under the slider, at its ends (the full-screen player), rather than at its sides.
  final bool timesBelow;

  @override
  State<SeekSlider> createState() => _SeekSliderState();
}

class _SeekSliderState extends State<SeekSlider> {
  /// Where the slider is held, in place of the position: while dragging, and after letting go
  /// until the position gets there (from another device, that comes with its next report).
  Duration? _held;
  bool _dragging = false;
  Timer? _letGo;

  @override
  void dispose() {
    _letGo?.cancel();
    super.dispose();
  }

  void _seekTo(Duration target) {
    setState(() {
      _dragging = false;
      _held = target;
    });
    _letGo?.cancel();
    _letGo = Timer(const Duration(seconds: 2), () {
      if (mounted) {
        setState(() => _held = null);
      }
    });
    unawaited(runCommand(context, () => ServicesScope.of(context).connect.seek(target)));
  }

  @override
  Widget build(BuildContext context) {
    final now = widget.now;
    final held = _held;

    if (held != null && !_dragging && (now.position - held).abs() < const Duration(seconds: 1)) {
      _held = null; // the position got there
    }

    final position = _held ?? now.position;
    final length = now.duration?.inMilliseconds ?? 0;
    final slider = SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackHeight: 3,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
      ),
      child: Slider(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        max: length > 0 ? length.toDouble() : 1,
        value: length > 0 ? position.inMilliseconds.clamp(0, length).toDouble() : 0,
        semanticFormatterCallback: (ms) => formatDuration(Duration(milliseconds: ms.round())),
        onChangeStart: length > 0 ? (_) => _dragging = true : null,
        onChanged: length > 0 ? (ms) => setState(() => _held = Duration(milliseconds: ms.round())) : null,
        onChangeEnd: length > 0 ? (ms) => _seekTo(Duration(milliseconds: ms.round())) : null,
      ),
    );
    final style = Theme.of(context).textTheme.bodySmall;
    final elapsed = Text(formatDuration(position), style: style);
    final total = Text(formatDuration(now.duration), style: style);

    if (widget.timesBelow) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          slider,
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [elapsed, total]),
          ),
        ],
      );
    }

    return Row(
      children: [
        SizedBox(
          width: 40,
          child: Align(alignment: Alignment.centerRight, child: elapsed),
        ),
        Expanded(child: slider),
        SizedBox(width: 40, child: total),
      ],
    );
  }
}

class ShuffleButton extends StatelessWidget {
  const ShuffleButton(this.now, {super.key});

  final NowPlaying now;

  @override
  Widget build(BuildContext context) {
    final connect = ServicesScope.of(context).connect;
    return IconButton(
      tooltip: now.shuffle ? 'Desativar aleatório' : 'Ativar aleatório',
      icon: Icon(Icons.shuffle, color: now.shuffle ? Theme.of(context).colorScheme.primary : null),
      onPressed: now.canShuffle ? () => runCommand(context, () => connect.setShuffle(!now.shuffle)) : null,
    );
  }
}

/// Goes off, then the whole queue, then the track, then off again.
class RepeatButton extends StatelessWidget {
  const RepeatButton(this.now, {super.key});

  final NowPlaying now;

  @override
  Widget build(BuildContext context) {
    final connect = ServicesScope.of(context).connect;
    return IconButton(
      tooltip: switch (now.repeat) {
        Repeat.off => 'Repetir a lista',
        Repeat.all => 'Repetir a faixa',
        Repeat.one => 'Não repetir',
      },
      icon: Icon(
        now.repeat == Repeat.one ? Icons.repeat_one : Icons.repeat,
        color: now.repeat == Repeat.off ? null : Theme.of(context).colorScheme.primary,
      ),
      onPressed: now.canRepeat
          ? () => runCommand(
              context,
              () => connect.setRepeat(switch (now.repeat) {
                Repeat.off => Repeat.all,
                Repeat.all => Repeat.one,
                Repeat.one => Repeat.off,
              }),
            )
          : null,
    );
  }
}
