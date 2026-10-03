import 'package:flutter/foundation.dart';

import '../player/player.dart';
import '../segue/client.dart';
import '../segue/protocol.dart';
import '../subsonic/models.dart';

/// What the now-playing bar shows, wherever it plays.
class NowPlaying {
  const NowPlaying({
    required this.playing,
    required this.position,
    this.title,
    this.artist,
    this.coverArt,
    this.duration,
    this.device,
  });

  final String? title;
  final String? artist;
  final String? coverArt;
  final bool playing;
  final Duration position;
  final Duration? duration;

  /// The other device it plays on; null when it plays here.
  final String? device;
}

/// Spotify's model: the app controls one device at a time, this one or another, and everything you
/// press (play an album, pause, skip) goes to it. Picking another device moves the music there.
class ConnectController extends ChangeNotifier {
  ConnectController({required this.player, this.client}) {
    player.addListener(notifyListeners);
    final hub = client;
    if (hub == null) return;
    hub.addListener(_hubChanged);
    hub.onCommand = (command, from) => player.obey(command);
    hub.onConnected = () => hub.sendState(player.report(full: true));
    player.onReport = hub.sendState;
  }

  final PlayerController player;

  /// Null when no hub was found: the app then only plays here.
  final SegueClient? client;

  String? _active;

  /// The device the app controls; null is this one.
  String? get activeId => _active;

  Device? get activeDevice => _active == null ? null : client?.devices[_active];

  /// The user's other players: online first, then by name.
  List<Device> get devices {
    final list = [...?client?.devices.values.where((d) => d.info.isPlayer)];
    list.sort((a, b) => a.online != b.online ? (a.online ? -1 : 1) : a.info.name.compareTo(b.info.name));
    return list;
  }

  NowPlaying? get nowPlaying {
    final device = activeDevice;
    if (device == null) {
      final song = player.current;
      if (song == null) return null;
      return NowPlaying(
        title: song.title,
        artist: song.artist,
        coverArt: song.coverArt,
        playing: player.playing,
        position: player.position,
        duration: song.duration,
      );
    }
    final state = device.state;
    final item = state?.current;
    return NowPlaying(
      title: item?.title,
      artist: item?.artist,
      coverArt: item?.id,
      playing: state?.status == PlaybackStatus.playing,
      position: Duration(milliseconds: client!.positionMs(device.id) ?? 0),
      duration: item?.durationMs == null ? null : Duration(milliseconds: item!.durationMs!),
      device: device.info.name,
    );
  }

  Future<Result> playSongs(List<Song> songs, int index) => _run(
    Command.setQueue(queue: [for (final song in songs) song.toQueueItem()], index: index, positionMs: 0, play: true),
    () => player.playQueue(songs, index: index),
  );

  Future<Result> toggle() => _run(const Command(CommandAction.toggle), player.toggle);

  Future<Result> next() => _run(const Command(CommandAction.next), player.next);

  Future<Result> previous() => _run(const Command(CommandAction.previous), player.previous);

  Future<Result> seek(Duration position) => _run(Command.seek(position.inMilliseconds), () => player.seek(position));

  /// Makes [deviceId] (null: this device) the one the app controls, moving the music there if the
  /// current one has any.
  Future<Result> switchTo(String? deviceId) async {
    final hub = client;
    if (deviceId == _active || hub == null) return const Result(ok: true);
    final me = hub.device.id;
    final hasMusic = _active == null ? player.queue.isNotEmpty : (activeDevice?.state?.queue?.isNotEmpty ?? false);
    if (hasMusic) {
      final result = await hub.transfer(_active ?? me, deviceId ?? me);
      if (!result.ok) return result;
    }
    _active = deviceId;
    notifyListeners();
    return const Result(ok: true);
  }

  /// Picks up here what a device that went offline was playing.
  Future<Result> continueFrom(String deviceId) async {
    final result = await client!.transfer(deviceId, client!.device.id);
    if (result.ok) {
      _active = null;
      notifyListeners();
    }
    return result;
  }

  Future<Result> _run(Command command, Future<void> Function() here) async {
    final target = _active;
    if (target != null) return client!.command(target, command);
    try {
      await here();
      return const Result(ok: true);
    } on CommandFailed catch (e) {
      return Result(ok: false, error: e.message);
    }
  }

  void _hubChanged() {
    if (_active != null && client!.devices[_active] == null) _active = null; // that device is gone
    notifyListeners();
  }

  @override
  void dispose() {
    player.removeListener(notifyListeners);
    client?.removeListener(_hubChanged);
    super.dispose();
  }
}
