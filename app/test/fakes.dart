import 'dart:async';

import 'package:segue/player/engine.dart';
import 'package:segue/segue/protocol.dart';

/// An engine with no audio: a queue and a clock, like the real one.
class FakeEngine implements AudioEngine {
  final _changes = StreamController<void>.broadcast(sync: true);
  List<Uri> tracks = [];
  int _index = 0;
  bool _playing = false;
  int _volume = 100;
  List<int> _order = [];
  Repeat _repeat = Repeat.off;
  bool _shuffle = false;
  Duration _position = Duration.zero;
  DateTime _since = DateTime.now();

  @override
  Stream<void> get changes => _changes.stream;

  @override
  bool get playing => _playing;

  @override
  int get index => _index;

  @override
  Duration get position => _playing ? _position + DateTime.now().difference(_since) : _position;

  @override
  int get volume => _volume;

  @override
  List<int> get order => _order;

  @override
  Repeat get repeat => _repeat;

  @override
  bool get shuffle => _shuffle;

  @override
  Future<void> open(List<Uri> tracks, {required int index, required Duration position, required bool play}) async {
    this.tracks = tracks;
    _order = [for (var i = 0; i < tracks.length; i++) i];
    _index = index;
    if (_shuffle) _shuffleOrder();
    _seek(position);
    _playing = play;
    _changes.add(null);
  }

  @override
  Future<void> setRepeat(Repeat mode) async {
    _repeat = mode;
    _changes.add(null);
  }

  @override
  Future<void> setShuffle(bool on) async {
    if (on == _shuffle) return;
    _shuffle = on;
    if (on) {
      _shuffleOrder();
    } else if (_order.isNotEmpty) {
      _index = _order[_index];
      _order = [for (var i = 0; i < _order.length; i++) i];
    }
    _changes.add(null);
  }

  /// A predictable shuffle: the current track first, then the others backwards.
  void _shuffleOrder() {
    if (_order.isEmpty) return;
    final current = _order[_index];
    _order = [current, ..._order.reversed.where((track) => track != current)];
    _index = 0;
  }

  @override
  Future<void> play() async => _setPlaying(true);

  @override
  Future<void> pause() async => _setPlaying(false);

  @override
  Future<void> stop() async {
    tracks = [];
    _order = [];
    _index = 0;
    _seek(Duration.zero);
    _playing = false;
    _changes.add(null);
  }

  @override
  Future<void> jump(int index) async {
    _index = index;
    _seek(Duration.zero);
    _playing = true;
    _changes.add(null);
  }

  @override
  Future<void> seek(Duration position) async => _seek(position); // like media_kit: not a change

  @override
  Future<void> setVolume(int volume) async {
    _volume = volume;
    _changes.add(null);
  }

  @override
  Future<void> dispose() => _changes.close();

  void _setPlaying(bool playing) {
    _seek(position);
    _playing = playing;
    _changes.add(null);
  }

  void _seek(Duration position) {
    _position = position;
    _since = DateTime.now();
  }
}
