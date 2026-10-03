import 'dart:async';

import 'package:flutter/foundation.dart';

import '../segue/client.dart';
import '../segue/protocol.dart';
import '../subsonic/api.dart';
import '../subsonic/models.dart';
import 'engine.dart';

/// This device's player: the queue, playback, and the commands other devices send it.
class PlayerController extends ChangeNotifier {
  PlayerController(this._engine, this._api) {
    _subscription = _engine.changes.listen((_) => _changed());
  }

  final AudioEngine _engine;
  final SubsonicApi _api;
  late final StreamSubscription<void> _subscription;
  List<Song> _queue = const [];
  bool _queueChanged = false;

  /// Receives this player's state after every change, for the hub.
  void Function(PlayerState state)? onReport;

  List<Song> get queue => _queue;
  int get index => _engine.index;
  bool get playing => _engine.playing;
  Duration get position => _engine.position;
  int get volume => _engine.volume;
  Song? get current => index >= 0 && index < _queue.length ? _queue[index] : null;

  PlaybackStatus get status => _queue.isEmpty
      ? PlaybackStatus.stopped
      : playing
      ? PlaybackStatus.playing
      : PlaybackStatus.paused;

  Future<void> playQueue(List<Song> songs, {int index = 0, Duration position = Duration.zero, bool play = true}) async {
    _queue = List.unmodifiable(songs);
    _queueChanged = true;
    await _engine.open(
      [for (final song in songs) _api.streamUrl(song.id)],
      index: index,
      position: position,
      play: play,
    );
    _changed();
  }

  Future<void> play() => _engine.play();

  Future<void> pause() => _engine.pause();

  Future<void> toggle() => playing ? _engine.pause() : _engine.play();

  Future<void> next() => _jump(index + 1);

  Future<void> previous() => _jump(index - 1);

  Future<void> seek(Duration position) async {
    await _engine.seek(position);
    _changed(); // a seek doesn't show in the engine's changes
  }

  Future<void> setVolume(int volume) => _engine.setVolume(volume.clamp(0, 100));

  Future<void> stop() async {
    await _engine.stop();
    _queue = const [];
    _queueChanged = true;
    _changed();
  }

  /// Carries out a command from another device.
  Future<void> obey(Command command) async {
    switch (command.action) {
      case CommandAction.play:
        await _engine.play();
      case CommandAction.pause:
        await _engine.pause();
      case CommandAction.toggle:
        await toggle();
      case CommandAction.stop:
        await stop();
      case CommandAction.next:
        await next();
      case CommandAction.previous:
        await previous();
      case CommandAction.seek:
        await seek(Duration(milliseconds: command.positionMs!));
      case CommandAction.setVolume:
        await setVolume(command.volume!);
      case CommandAction.setQueue:
        // Items the hub couldn't express as Subsonic ids can't be played here: skip them, keeping
        // the current track current.
        final items = command.queue!;
        final playable = [
          for (final item in items)
            if (item.id != null) Song.fromQueueItem(item),
        ];
        if (playable.isEmpty) throw const CommandFailed('nothing playable');
        final skippedBefore = items.take(command.index!).where((item) => item.id == null).length;
        await playQueue(
          playable,
          index: (command.index! - skippedBefore).clamp(0, playable.length - 1),
          position: Duration(milliseconds: command.positionMs!),
          play: command.play!,
        );
    }
  }

  /// This player's state for the hub. The queue goes only when it changed, or when [full].
  PlayerState report({bool full = false}) => PlayerState(
    status: status,
    positionMs: position.inMilliseconds,
    queue: full || _queueChanged ? [for (final song in _queue) song.toQueueItem()] : null,
    index: index,
    volume: volume,
  );

  Future<void> _jump(int to) async {
    if (to < 0 || to >= _queue.length) throw const CommandFailed('no such track');
    await _engine.jump(to);
  }

  void _changed() {
    notifyListeners();
    final state = report();
    _queueChanged = false;
    onReport?.call(state);
  }

  @override
  Future<void> dispose() async {
    await _subscription.cancel();
    await _engine.dispose();
    super.dispose();
  }
}
