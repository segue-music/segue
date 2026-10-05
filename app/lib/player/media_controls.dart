import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../connect/connect.dart';
import '../segue/protocol.dart';
import '../server/server.dart';

/// The system's media controls (MPRIS on Linux: media keys, the desktop's player widget, KDE
/// Connect...; Now Playing on iOS: the lock screen, Control Center, CarPlay, headphone buttons) for
/// what the now-playing bar shows: this device's playback, or the device it follows.
class MediaControls extends BaseAudioHandler with SeekHandler {
  ConnectController? _connect;
  MediaServer? _api;
  Timer? _tick;

  /// Starts the system's media service, on the platforms where the app sets it up: Linux (MPRIS)
  /// and iOS for now. Null when it can't, e.g. without a D-Bus session.
  static Future<MediaControls?> start() async {
    if (!Platform.isLinux && !Platform.isIOS) {
      return null;
    }

    try {
      return await AudioService.init(
        builder: MediaControls.new,
        config: const AudioServiceConfig(
          // On Linux, the MPRIS bus name (with ".instance<pid>") and the name the desktop shows.
          androidNotificationChannelId: 'io.github.mateusguilherme.segue',
          androidNotificationChannelName: 'Segue',
        ),
      );
    } on Object catch (e) {
      debugPrint('media controls unavailable: $e');
      return null;
    }
  }

  /// Shows [connect]'s playback; null (signed out) shows nothing. [api] fetches the covers.
  void attach(ConnectController? connect, MediaServer? api) {
    _connect?.removeListener(_sync);
    _connect = connect;
    _api = api;
    connect?.addListener(_sync);
    _sync();
  }

  void _sync() {
    _tick?.cancel();
    final now = _connect?.nowPlaying;

    if (now?.title == null) {
      mediaItem.add(null);
      playbackState.add(PlaybackState());
      return;
    }

    final id = [now!.device, now.coverArt, now.title].join('|');

    if (mediaItem.value?.id != id) {
      mediaItem.add(
        MediaItem(
          id: id,
          title: now.title!,
          artist: now.device == null ? now.artist : '${now.artist ?? ''} (em ${now.device})',
          duration: now.duration,
        ),
      );
      unawaited(_loadCover(now.coverArt, id));
    }

    playbackState.add(
      PlaybackState(
        controls: [
          MediaControl.skipToPrevious,
          if (now.playing) MediaControl.pause else MediaControl.play,
          MediaControl.skipToNext,
        ],
        systemActions: const {MediaAction.seek},
        processingState: AudioProcessingState.ready,
        playing: now.playing,
        updatePosition: now.position,
      ),
    );

    // MPRIS only learns the position from these updates: refresh it while playing.
    if (now.playing) {
      _tick = Timer(const Duration(seconds: 1), _sync);
    }
  }

  /// The cover goes to the system as a file: its server URL carries the login token.
  Future<void> _loadCover(String? coverId, String itemId) async {
    final api = _api;

    if (coverId == null || api == null) {
      return;
    }

    try {
      final dir = Directory('${(await getTemporaryDirectory()).path}/segue-covers');
      final file = File('${dir.path}/${coverId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}.jpg');

      if (!await file.exists()) {
        await dir.create(recursive: true);
        await file.writeAsBytes(await api.coverArt(coverId, size: 512));
      }

      final item = mediaItem.value;

      if (item?.id == itemId) {
        mediaItem.add(item!.copyWith(artUri: file.uri));
      }
    } on Object catch (e) {
      debugPrint('cover for the media controls: $e'); // the controls just go without it
    }
  }

  @override
  Future<void> play() => _do((connect) => connect.play());

  @override
  Future<void> pause() => _do((connect) => connect.pause());

  @override
  Future<void> stop() => pause();

  @override
  Future<void> skipToNext() => _do((connect) => connect.next());

  @override
  Future<void> skipToPrevious() => _do((connect) => connect.previous());

  @override
  Future<void> seek(Duration position) => _do((connect) => connect.seek(position));

  Future<void> _do(Future<Result> Function(ConnectController connect) action) async {
    final connect = _connect;

    if (connect != null) {
      await action(connect);
    }
  }
}
