import 'dart:async';

import 'package:segue/player/engine.dart';

/// An engine with no audio: a queue and a clock, like the real one.
class FakeEngine implements AudioEngine {
  final _changes = StreamController<void>.broadcast(sync: true);
  List<Uri> tracks = [];
  int _index = 0;
  bool _playing = false;
  int _volume = 100;
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
  Future<void> open(List<Uri> tracks, {required int index, required Duration position, required bool play}) async {
    this.tracks = tracks;
    _index = index;
    _seek(position);
    _playing = play;
    _changes.add(null);
  }

  @override
  Future<void> play() async => _setPlaying(true);

  @override
  Future<void> pause() async => _setPlaying(false);

  @override
  Future<void> stop() async {
    tracks = [];
    _index = 0;
    _seek(Duration.zero);
    _playing = false;
    _changes.add(null);
  }

  @override
  Future<void> jump(int index) async {
    _index = index;
    _seek(Duration.zero);
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
