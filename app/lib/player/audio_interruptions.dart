import 'dart:async';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';

import 'player.dart';

/// What the system does to this device's playback, on iOS: a call or another app's audio interrupts
/// it, and the car or the headphones going away stops it. libmpv knows of neither: without this the
/// player would go on "playing" in silence through a call, or carry on out of the phone's speaker
/// after leaving the car.
class AudioInterruptions {
  AudioInterruptions(Stream<AudioInterruptionEvent> interruptions, Stream<void> becomingNoisy) {
    interruptions.listen(_interrupted);
    becomingNoisy.listen((_) => _pause());
  }

  /// Sets the app's audio session up for music, on iOS: it keeps playing in the background and with
  /// the silent switch on, and calls interrupt it. Null elsewhere, or when it can't.
  static Future<AudioInterruptions?> start() async {
    if (!Platform.isIOS) {
      return null;
    }

    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
      return AudioInterruptions(session.interruptionEventStream, session.becomingNoisyEventStream);
    } on Object catch (e) {
      debugPrint('audio session unavailable: $e');
      return null;
    }
  }

  PlayerController? _player;

  // Whether an interruption paused the music, which then plays again when it ends.
  bool _resume = false;

  /// Acts on [player], this device's; null (signed out) on nothing.
  void attach(PlayerController? player) {
    _player = player;
    _resume = false;
  }

  void _interrupted(AudioInterruptionEvent event) {
    final player = _player;

    if (player == null) {
      return;
    }

    if (event.begin) {
      // The system lowers our volume itself, and raises it again.
      if (event.type == AudioInterruptionType.duck) {
        return;
      }

      final playing = player.playing;
      _pause();
      _resume = playing;
    } else {
      // A pause is the system saying to resume; unknown, that we shouldn't.
      if (_resume && event.type == AudioInterruptionType.pause) {
        unawaited(player.play());
      }

      _resume = false;
    }
  }

  void _pause() {
    _resume = false;
    final player = _player;

    if (player != null && player.playing) {
      unawaited(player.pause());
    }
  }
}
