import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import '../segue/protocol.dart';

/// What [PlayerController] needs from an audio backend. [MediaKitEngine] is the real one; the tests
/// use a fake.
abstract class AudioEngine {
  /// Fires when [playing], [index], [volume], [order], [repeat] or [shuffle] change, and when the
  /// track starts over by itself (repeating it). Position ticks don't count.
  Stream<void> get changes;

  bool get playing;
  int get index;
  Duration get position;

  /// 0 to 100.
  int get volume;

  /// The play order: for each position, the index of the track in what [open] got. Shuffled while
  /// [shuffle] is on; [index] is a position in it.
  List<int> get order;

  Repeat get repeat;
  bool get shuffle;

  Future<void> open(List<Uri> tracks, {required int index, required Duration position, required bool play});
  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> jump(int index);
  Future<void> seek(Duration position);
  Future<void> setVolume(int volume);
  Future<void> setRepeat(Repeat mode);

  /// On, shuffles the tracks, the current one still playing; off, back to the order [open] got.
  /// It stays on for the tracks opened next.
  Future<void> setShuffle(bool on);

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
        final inOrder = [for (final media in playlist.medias) media.uri];
        // Another track, by itself: from its start. A shuffle keeps the same one current.
        if (_at(inOrder, playlist.index) != _at(_inOrder, _index)) _moved(Duration.zero);
        _inOrder = inOrder;
        _index = playlist.index;
        _changes.add(null);
      }),
      stream.playlistMode.listen((_) => _changes.add(null)),
      stream.volume.listen((_) => _changes.add(null)),
      stream.completed.listen((_) => _changes.add(null)),
      stream.position.listen((reported) {
        if (_moving) {
          if ((reported - position).abs() < const Duration(seconds: 1)) _movedTo = null;
        } else if (reported < _lastPosition - const Duration(milliseconds: 500)) {
          _changes.add(null); // went back by itself: the track started over, repeating it
        }
        _lastPosition = reported;
      }),
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

  // The tracks as open got them, and in play order (shuffled, or not), as media_kit's URIs.
  List<String> _opened = const [];
  List<String> _inOrder = const [];

  // media_kit turns shuffle off with every open; this is the mode, which stays.
  bool _shuffle = false;

  Duration _lastPosition = Duration.zero;

  static String? _at(List<String> tracks, int index) => index >= 0 && index < tracks.length ? tracks[index] : null;

  // Where playback went with a seek, a jump or a new track, until media_kit's position gets there:
  // its state.position keeps the old place for a moment, and the player's report to the hub,
  // right after, would send that to the other devices. Past [_trustMoveFor], media_kit's is back.
  Duration? _movedTo;
  DateTime _movedAt = DateTime.now();
  static const _trustMoveFor = Duration(seconds: 2);

  void _moved(Duration to) {
    _movedTo = to;
    _movedAt = DateTime.now();
  }

  bool get _moving => _movedTo != null && DateTime.now().difference(_movedAt) <= _trustMoveFor;

  @override
  Stream<void> get changes => _changes.stream;

  @override
  bool get playing => _player.state.playing;

  @override
  int get index => _index;

  @override
  Duration get position {
    if (!_moving) return _player.state.position;
    final since = DateTime.now().difference(_movedAt);
    return playing ? _movedTo! + since : _movedTo!;
  }

  @override
  int get volume => _player.state.volume.round();

  @override
  List<int> get order {
    final unused = <String, List<int>>{};
    for (final (i, track) in _opened.indexed) {
      (unused[track] ??= []).add(i);
    }
    final order = <int>[];
    for (final track in _inOrder) {
      final positions = unused[track];
      if (positions == null || positions.isEmpty) return [for (var i = 0; i < _opened.length; i++) i];
      order.add(positions.removeAt(0));
    }
    return order;
  }

  @override
  Repeat get repeat => switch (_player.state.playlistMode) {
    PlaylistMode.none => Repeat.off,
    PlaylistMode.loop => Repeat.all,
    PlaylistMode.single => Repeat.one,
  };

  @override
  bool get shuffle => _shuffle;

  @override
  Future<void> setRepeat(Repeat mode) async {
    await _ready;
    await _player.setPlaylistMode(switch (mode) {
      Repeat.off => PlaylistMode.none,
      Repeat.all => PlaylistMode.loop,
      Repeat.one => PlaylistMode.single,
    });
  }

  @override
  Future<void> setShuffle(bool on) async {
    await _ready;
    _shuffle = on;
    if (_opened.isNotEmpty) await _player.setShuffle(on);
    _changes.add(null);
  }

  @override
  Future<void> open(List<Uri> tracks, {required int index, required Duration position, required bool play}) async {
    await _ready;
    final medias = [for (final track in tracks) Media(track.toString())];
    _opened = _inOrder = [for (final media in medias) media.uri];
    _index = index;
    _moved(position);
    final playlist = Playlist(medias, index: index);
    if (position == Duration.zero) {
      await _player.open(playlist, play: play);
    } else {
      // Seeking only works once the track has loaded, which the duration announces.
      final loaded = _player.stream.duration.firstWhere((d) => d > Duration.zero);
      await _player.open(playlist, play: false);
      await loaded.timeout(const Duration(seconds: 10), onTimeout: () => Duration.zero);
      await seek(position);
      if (play) await _player.play();
    }
    if (_shuffle) await _player.setShuffle(true);
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() {
    _index = 0;
    _opened = _inOrder = const [];
    _moved(Duration.zero);
    return _player.stop();
  }

  @override
  Future<void> jump(int index) {
    _index = index;
    _moved(Duration.zero);
    return _player.jump(index);
  }

  @override
  Future<void> seek(Duration position) {
    _moved(position);
    return _player.seek(position);
  }

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
