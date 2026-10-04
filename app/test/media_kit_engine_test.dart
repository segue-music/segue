// MediaKitEngine on the real libmpv, with the audio sent nowhere. Pins media_kit behaviour the app
// depends on, so that an upgrade that changes it shows up here. Needs libmpv (the dev image has it).
import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:segue/player/engine.dart';
import 'package:segue/segue/protocol.dart';

bool get hasLibmpv {
  for (final name in ['libmpv.so.2', 'libmpv.so']) {
    try {
      DynamicLibrary.open(name);
      return true;
    } on ArgumentError {
      continue;
    }
  }
  return false;
}

/// A short tone as a WAV file.
Uri tone(Directory dir, int n, {double seconds = 4}) {
  const rate = 8000;
  final samples = (rate * seconds).round();
  final data = ByteData(44 + samples * 2);
  void text(int offset, String s) => s.codeUnits.asMap().forEach((i, c) => data.setUint8(offset + i, c));
  text(0, 'RIFF');
  data.setUint32(4, 36 + samples * 2, Endian.little);
  text(8, 'WAVEfmt ');
  data
    ..setUint32(16, 16, Endian.little)
    ..setUint16(20, 1, Endian.little)
    ..setUint16(22, 1, Endian.little)
    ..setUint32(24, rate, Endian.little)
    ..setUint32(28, rate * 2, Endian.little)
    ..setUint16(32, 2, Endian.little)
    ..setUint16(34, 16, Endian.little);
  text(36, 'data');
  data.setUint32(40, samples * 2, Endian.little);
  for (var i = 0; i < samples; i++) {
    data.setInt16(44 + i * 2, (sin(2 * pi * (300 + 100 * n) * i / rate) * 8000).round(), Endian.little);
  }
  return (File('${dir.path}/t$n.wav')..writeAsBytesSync(data.buffer.asUint8List())).uri;
}

void main() {
  late MediaKitEngine engine;
  late Directory dir;

  setUp(() {
    MediaKit.ensureInitialized();
    engine = MediaKitEngine(silent: true);
    dir = Directory.systemTemp.createTempSync('segue-engine');
  });
  tearDown(() async {
    await engine.dispose();
    dir.deleteSync(recursive: true);
  });

  test('opening at another track says that track, right away and later', () async {
    final tracks = [for (var i = 0; i < 3; i++) tone(dir, i)];
    await engine.open(tracks, index: 0, position: Duration.zero, play: true);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    // What the app does when another song of the album is picked while one plays:
    await engine.open(tracks, index: 2, position: Duration.zero, play: true);
    expect(engine.index, 2);
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(engine.index, 2);
    expect(engine.playing, isTrue);
  }, skip: hasLibmpv ? false : 'needs libmpv');

  test('jumping and moving on by itself announce the new track', () async {
    final tracks = [tone(dir, 0, seconds: 1), tone(dir, 1), tone(dir, 2)];
    final changes = <int>[];
    final subscription = engine.changes.listen((_) => changes.add(engine.index));
    await engine.open(tracks, index: 0, position: Duration.zero, play: true);
    await Future<void>.delayed(const Duration(milliseconds: 1800)); // the first track ends
    expect(engine.index, 1);
    expect(changes, contains(1));
    await engine.jump(2);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(engine.index, 2);
    expect(changes.last, 2);
    await subscription.cancel();
  }, skip: hasLibmpv ? false : 'needs libmpv');

  // A jump is what a tap in the queue does: that track, from its start, playing.

  test('a jump plays, even from paused', () async {
    final tracks = [for (var i = 0; i < 3; i++) tone(dir, i)];
    await engine.open(tracks, index: 0, position: Duration.zero, play: false);
    await engine.jump(2);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(engine.index, 2);
    expect(engine.playing, isTrue);
  }, skip: hasLibmpv ? false : 'needs libmpv');

  test('a jump to the current track starts it over', () async {
    final tracks = [for (var i = 0; i < 2; i++) tone(dir, i, seconds: 20)];
    await engine.open(tracks, index: 0, position: const Duration(seconds: 15), play: true);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await engine.jump(0);
    // Past the time the engine trusts the position it commanded over media_kit's.
    await Future<void>.delayed(const Duration(milliseconds: 2500));
    expect(engine.index, 0);
    expect(engine.playing, isTrue);
    expect(engine.position, lessThan(const Duration(seconds: 8)));
  }, skip: hasLibmpv ? false : 'needs libmpv');

  test('after the last track ends, a jump plays the track picked', () async {
    final tracks = [for (var i = 0; i < 3; i++) tone(dir, i, seconds: 1)];
    await engine.open(tracks, index: 2, position: Duration.zero, play: true);
    await Future<void>.delayed(const Duration(milliseconds: 1500)); // the queue ends
    await engine.jump(1);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(engine.index, 1);
    expect(engine.playing, isTrue);
  }, skip: hasLibmpv ? false : 'needs libmpv');

  test('after the last track ends, a jump to it plays it again', () async {
    final tracks = [for (var i = 0; i < 3; i++) tone(dir, i, seconds: 1)];
    await engine.open(tracks, index: 2, position: Duration.zero, play: true);
    await Future<void>.delayed(const Duration(milliseconds: 1500)); // the queue ends
    await engine.jump(2);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(engine.index, 2);
    expect(engine.playing, isTrue);
  }, skip: hasLibmpv ? false : 'needs libmpv');

  // The player reports its position to the hub right after each of these: a position still at the
  // old place goes to the other devices, which then count from there.

  test('a seek shows in the position as soon as it returns', () async {
    await engine.open([tone(dir, 0)], index: 0, position: Duration.zero, play: true);
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    await engine.seek(Duration.zero);
    expect(engine.position, lessThan(const Duration(milliseconds: 500)));
  }, skip: hasLibmpv ? false : 'needs libmpv');

  test('opening at a position shows it as soon as it returns', () async {
    await engine.open([tone(dir, 0)], index: 0, position: const Duration(seconds: 2), play: false);
    expect(engine.position.inMilliseconds, closeTo(2000, 200));
  }, skip: hasLibmpv ? false : 'needs libmpv');

  test('a new track, by a jump or moving on by itself, announces itself at its start', () async {
    final tracks = [tone(dir, 0, seconds: 1), tone(dir, 1), tone(dir, 2)];
    final announced = <int, Duration>{}; // track → the position when it was first announced
    final subscription = engine.changes.listen((_) => announced.putIfAbsent(engine.index, () => engine.position));
    await engine.open(tracks, index: 0, position: Duration.zero, play: true);
    await Future<void>.delayed(const Duration(milliseconds: 2200)); // moves on to track 1 at 1 s
    await engine.jump(2);
    expect(engine.position, lessThan(const Duration(milliseconds: 500)));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(announced.keys, containsAll([1, 2]));
    expect(announced[1], lessThan(const Duration(milliseconds: 500)));
    expect(announced[2], lessThan(const Duration(milliseconds: 500)));
    await subscription.cancel();
  }, skip: hasLibmpv ? false : 'needs libmpv');

  test('shuffle keeps the current track playing, and off brings back the order it had', () async {
    final tracks = [for (var i = 0; i < 5; i++) tone(dir, i)];
    await engine.open(tracks, index: 2, position: Duration.zero, play: true);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(engine.order, [0, 1, 2, 3, 4]);
    await engine.setShuffle(true);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(engine.shuffle, isTrue);
    expect([...engine.order]..sort(), [0, 1, 2, 3, 4]);
    expect(engine.order[engine.index], 2, reason: 'the same track, still current');
    expect(engine.playing, isTrue);
    expect(engine.position, greaterThan(const Duration(milliseconds: 500)), reason: 'not started over');
    await engine.setShuffle(false);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(engine.order, [0, 1, 2, 3, 4]);
    expect(engine.index, 2);
  }, skip: hasLibmpv ? false : 'needs libmpv');

  test('shuffle stays on for the tracks opened next', () async {
    final tracks = [for (var i = 0; i < 8; i++) tone(dir, i)];
    await engine.setShuffle(true);
    await engine.open(tracks, index: 3, position: Duration.zero, play: true);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(engine.shuffle, isTrue);
    expect(engine.order[engine.index], 3);
    expect(engine.order, isNot([0, 1, 2, 3, 4, 5, 6, 7])); // 1 in 40320 to be so by chance
  }, skip: hasLibmpv ? false : 'needs libmpv');

  test('repeat one starts the track over, and says so', () async {
    // With the audio sent nowhere, mpv goes through a track faster than it lasts: this one, of 2 s,
    // starts over after about 1.3 s.
    final tracks = [tone(dir, 0, seconds: 2), tone(dir, 1)];
    await engine.setRepeat(Repeat.one);
    expect(engine.repeat, Repeat.one);
    final opened = DateTime.now();
    final restarts = <Duration>[];
    final subscription = engine.changes.listen((_) {
      if (DateTime.now().difference(opened) > const Duration(milliseconds: 400)) restarts.add(engine.position);
    });
    await engine.open(tracks, index: 0, position: Duration.zero, play: true);
    await Future<void>.delayed(const Duration(milliseconds: 2500));
    expect(engine.index, 0);
    expect(restarts, contains(lessThan(const Duration(milliseconds: 500))));
    await subscription.cancel();
  }, skip: hasLibmpv ? false : 'needs libmpv');

  test('repeat all goes back to the first track after the last', () async {
    final tracks = [tone(dir, 0, seconds: 1), tone(dir, 1, seconds: 1)];
    await engine.setRepeat(Repeat.all);
    await engine.open(tracks, index: 1, position: Duration.zero, play: true);
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    expect(engine.index, 0);
    expect(engine.playing, isTrue);
  }, skip: hasLibmpv ? false : 'needs libmpv');
}
