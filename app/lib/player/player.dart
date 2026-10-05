import 'dart:async';

import 'package:flutter/foundation.dart';

import '../segue/client.dart';
import '../segue/protocol.dart';
import '../server/models.dart';
import '../server/server.dart';
import 'engine.dart';

/// This device's player: the queue, playback, and the commands other devices send it.
class PlayerController extends ChangeNotifier {
  PlayerController(this._engine, this._api) {
    _subscription = _engine.changes.listen((_) => _changed());
  }

  final AudioEngine _engine;
  final MediaServer _api;
  late final StreamSubscription<void> _subscription;
  // The songs as playQueue got them, and _queue: them in the engine's play order (shuffled, or not).
  List<Song> _opened = const [];
  List<int> _order = const [];
  List<Song> _queue = const [];
  bool _queueChanged = false;

  /// Receives this player's state after every change, for the hub.
  void Function(PlayerState state)? onReport;

  List<Song> get queue => _queue;
  int get index => _engine.index;
  bool get playing => _engine.playing;
  Duration get position => _engine.position;
  int get volume => _engine.volume;
  Repeat get repeat => _engine.repeat;
  bool get shuffle => _engine.shuffle;
  Song? get current => index >= 0 && index < _queue.length ? _queue[index] : null;

  PlaybackStatus get status => _queue.isEmpty
      ? PlaybackStatus.stopped
      : playing
      ? PlaybackStatus.playing
      : PlaybackStatus.paused;

  Future<void> playQueue(List<Song> songs, {int index = 0, Duration position = Duration.zero, bool play = true}) async {
    _queue = _opened = List.unmodifiable(songs);
    _order = const []; // so that the engine's order, shuffled or not, is taken up
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

  /// The next track; after the last one, the first, unless repeat is off (SPEC.md, section 5).
  Future<void> next() => _jump(index + 1 >= _queue.length && repeat != Repeat.off ? 0 : index + 1);

  /// Back to the start of the track; in its first seconds, to the previous one (SPEC.md, section 5).
  Future<void> previous() async {
    if (index == 0 || position > previousGrace) {
      return seek(Duration.zero);
    }

    await _jump(index - 1);
  }

  /// The track at [index] of [queue] from its start, playing; the current one starts over.
  Future<void> jump(int index) async {
    await _jump(index);
    _changed(); // starting the current track over doesn't show in the engine's changes
  }

  /// Up to where "previous" goes to the previous track rather than to the start of this one.
  static const previousGrace = Duration(seconds: 3);

  Future<void> seek(Duration position) async {
    await _engine.seek(position);
    _changed(); // a seek doesn't show in the engine's changes
  }

  Future<void> setVolume(int volume) => _engine.setVolume(volume.clamp(0, 100));

  Future<void> setRepeat(Repeat mode) async {
    await _engine.setRepeat(mode);
    _changed();
  }

  Future<void> setShuffle(bool on) async {
    await _engine.setShuffle(on);
    _changed();
  }

  Future<void> stop() async {
    await _engine.stop();
    _queue = _opened = const [];
    _order = const [];
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
      case CommandAction.jump:
        await jump(command.index!);
      case CommandAction.seek:
        await seek(Duration(milliseconds: command.positionMs!));
      case CommandAction.setVolume:
        await setVolume(command.volume!);
      case CommandAction.setRepeat:
        await setRepeat(command.repeat!);
      case CommandAction.setShuffle:
        await setShuffle(command.shuffle!);
      case CommandAction.setQueue:
        // Items the hub couldn't express in this device's API can't be played here: skip them,
        // keeping the current track current.
        final items = command.queue!;
        final playable = [
          for (final item in items)
            if (item.id != null) Song.fromQueueItem(item),
        ];

        if (playable.isEmpty) {
          throw const CommandFailed('nothing playable');
        }

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
    repeat: repeat,
    shuffle: shuffle,
  );

  Future<void> _jump(int to) async {
    if (to < 0 || to >= _queue.length) {
      throw const CommandFailed('no such track');
    }

    await _engine.jump(to);
  }

  void _changed() {
    _followOrder();
    notifyListeners();
    final state = report();
    _queueChanged = false;
    onReport?.call(state);
  }

  /// Puts [_queue] in the engine's play order, which a shuffle changes.
  void _followOrder() {
    final order = _engine.order;

    if (listEquals(order, _order) || order.length != _opened.length) {
      return;
    }

    _order = List.unmodifiable(order);
    _queue = List.unmodifiable([for (final i in order) _opened[i]]);
    _queueChanged = true;
  }

  @override
  Future<void> dispose() async {
    await _subscription.cancel();
    await _engine.dispose();
    super.dispose();
  }
}
