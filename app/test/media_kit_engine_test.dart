// MediaKitEngine on the real libmpv, with the audio sent nowhere. Pins media_kit behaviour the app
// depends on, so that an upgrade that changes it shows up here. Needs libmpv (the dev image has it).
import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:segue/player/engine.dart';

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
}
