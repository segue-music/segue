import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

/// What [PlayerController] needs from an audio backend. [MediaKitEngine] is the real one; the tests
/// use a fake.
abstract class AudioEngine {
  /// Fires when [playing], [index] or [volume] change. Position ticks don't count.
  Stream<void> get changes;

  bool get playing;
  int get index;
  Duration get position;

  /// 0 to 100.
  int get volume;

  Future<void> open(List<Uri> tracks, {required int index, required Duration position, required bool play});
  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> jump(int index);
  Future<void> seek(Duration position);
  Future<void> setVolume(int volume);
  Future<void> dispose();
}

/// Plays through media_kit (libmpv), on every platform.
class MediaKitEngine implements AudioEngine {
  /// [silent] sends the audio nowhere: for tests on a machine without sound.
  MediaKitEngine({@visibleForTesting bool silent = false}) {
    _ready = silent ? (_player.platform as NativePlayer).setProperty('ao', 'null') : Future.value();
    final stream = _player.stream;
    _subscriptions = [
      stream.playing.listen((_) => _changes.add(null)),
      stream.playlist.listen((playlist) {
        _index = playlist.index;
        _changes.add(null);
      }),
      stream.volume.listen((_) => _changes.add(null)),
      stream.completed.listen((_) => _changes.add(null)),
    ];
  }

  final _player = Player();
  final _changes = StreamController<void>.broadcast();
  late final List<StreamSubscription<Object?>> _subscriptions;
  late final Future<void> _ready;

  // The current track, from the playlist events and our own calls. media_kit's
  // state.playlist.index can't be trusted: on every open it drops to 0 for a moment, unannounced,
  // and comes back silently (its playlist stream skips a repeat of what it already announced).
  int _index = 0;

  @override
  Stream<void> get changes => _changes.stream;

  @override
  bool get playing => _player.state.playing;

  @override
  int get index => _index;

  @override
  Duration get position => _player.state.position;

  @override
  int get volume => _player.state.volume.round();

  @override
  Future<void> open(List<Uri> tracks, {required int index, required Duration position, required bool play}) async {
    await _ready;
    _index = index;
    final playlist = Playlist([for (final track in tracks) Media(track.toString())], index: index);
    if (position == Duration.zero) {
      await _player.open(playlist, play: play);
      return;
    }
    // Seeking only works once the track has loaded, which the duration announces.
    final loaded = _player.stream.duration.firstWhere((d) => d > Duration.zero);
    await _player.open(playlist, play: false);
    await loaded.timeout(const Duration(seconds: 10), onTimeout: () => Duration.zero);
    await _player.seek(position);
    if (play) await _player.play();
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() {
    _index = 0;
    return _player.stop();
  }

  @override
  Future<void> jump(int index) {
    _index = index;
    return _player.jump(index);
  }

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> setVolume(int volume) => _player.setVolume(volume.toDouble());

  @override
  Future<void> dispose() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _changes.close();
    await _player.dispose();
  }
}
