import 'dart:async';

import 'package:flutter/foundation.dart';

import '../player/player.dart';
import '../segue/client.dart';
import '../segue/protocol.dart';
import '../server/models.dart';

/// What plays, wherever it plays: what the now-playing bar shows, and which song the lists mark.
class NowPlaying {
  const NowPlaying({
    required this.playing,
    required this.position,
    this.songId,
    this.title,
    this.artist,
    this.album,
    this.coverArt,
    this.duration,
    this.device,
    this.repeat = Repeat.off,
    this.shuffle = false,
    this.canRepeat = false,
    this.canShuffle = false,
    this.canJump = false,
  });

  /// Its id in the app's API (the hub gives the app other devices' songs in it), or null when the
  /// hub couldn't translate it.
  final String? songId;

  final String? title;
  final String? artist;
  final String? album;
  final String? coverArt;
  final bool playing;
  final Duration position;
  final Duration? duration;

  /// The other device it plays on; null when it plays here.
  final String? device;

  final Repeat repeat;
  final bool shuffle;

  /// Whether the device it plays on takes [ConnectController.setRepeat],
  /// [ConnectController.setShuffle] and [ConnectController.jump].
  final bool canRepeat;
  final bool canShuffle;
  final bool canJump;
}

/// Spotify's model: the app controls one device at a time, this one or another, and everything you
/// press (play an album, pause, skip) goes to it. Picking another device moves the music there, and
/// when any device starts playing, every app follows it.
class ConnectController extends ChangeNotifier {
  ConnectController({required this.player, this.client}) {
    player.addListener(_update);
    final hub = client;
    if (hub == null) return;
    hub.addListener(_update);
    hub.onCommand = (command, from) => player.obey(command);
    hub.onConnected = () => unawaited(_connected());
    player.onReport = hub.sendState;
  }

  final PlayerController player;

  /// Null when no hub was found: the app then only plays here.
  final SegueClient? client;

  String? _active;

  /// The device playing at the last update: [_here], another device's id, or null for none. A
  /// change means a device started playing, and the app follows it.
  String? _playing;
  static const _here = ''; // the hub never gives a device an empty id
  bool _restored = false;

  /// The device the app controls; null is this one.
  String? get activeId => _active;

  /// The device playing now, or null for none (or this one).
  String? get playingId => _playing == _here ? null : _playing;

  Device? get activeDevice => _active == null ? null : client?.devices[_active];

  /// The user's other players that are online, by name. Offline ones can't play, so they are left
  /// out, though the hub still lists them.
  List<Device> get devices {
    final list = [...?client?.devices.values.where((d) => d.info.isPlayer && d.online)];
    list.sort((a, b) => a.info.name.compareTo(b.info.name));
    return list;
  }

  NowPlaying? get nowPlaying {
    final device = activeDevice;
    if (device == null) {
      final song = player.current;
      if (song == null) return null;
      return NowPlaying(
        songId: song.id,
        title: song.title,
        artist: song.artist,
        album: song.album,
        coverArt: song.coverArt,
        playing: player.playing,
        position: player.position,
        duration: song.duration,
        repeat: player.repeat,
        shuffle: player.shuffle,
        canRepeat: true,
        canShuffle: true,
        canJump: true,
      );
    }
    final state = device.state;
    final item = state?.current;
    return NowPlaying(
      songId: item?.id,
      title: item?.title,
      artist: item?.artist,
      album: item?.album,
      coverArt: item?.id,
      playing: state?.status == PlaybackStatus.playing,
      position: Duration(milliseconds: client!.positionMs(device.id) ?? 0),
      duration: item?.durationMs == null ? null : Duration(milliseconds: item!.durationMs!),
      device: device.info.name,
      repeat: state?.repeat ?? Repeat.off,
      shuffle: state?.shuffle ?? false,
      canRepeat: device.info.capabilities.contains(CommandAction.setRepeat),
      canShuffle: device.info.capabilities.contains(CommandAction.setShuffle),
      canJump: device.info.capabilities.contains(CommandAction.jump),
    );
  }

  /// The queue of the device the app controls, in its play order (shuffled, or not), and the
  /// current track's place in it.
  ({List<QueueItem> tracks, int index}) get queue {
    final device = activeDevice;
    if (device == null) return (tracks: [for (final song in player.queue) song.toQueueItem()], index: player.index);
    return (tracks: device.state?.queue ?? const [], index: device.state?.index ?? 0);
  }

  Future<Result> playSongs(List<Song> songs, int index) => _run(
    Command.setQueue(queue: [for (final song in songs) song.toQueueItem()], index: index, positionMs: 0, play: true),
    () => player.playQueue(songs, index: index),
  );

  Future<Result> play() => _run(const Command(CommandAction.play), player.play);

  Future<Result> pause() => _run(const Command(CommandAction.pause), player.pause);

  Future<Result> toggle() => _run(const Command(CommandAction.toggle), player.toggle);

  Future<Result> next() => _run(const Command(CommandAction.next), player.next);

  Future<Result> previous() => _run(const Command(CommandAction.previous), player.previous);

  /// Plays the track at [index] of [queue], from its start.
  Future<Result> jump(int index) => _run(Command.jump(index), () => player.jump(index));

  Future<Result> seek(Duration position) => _run(Command.seek(position.inMilliseconds), () => player.seek(position));

  Future<Result> setRepeat(Repeat mode) => _run(Command.setRepeat(mode), () => player.setRepeat(mode));

  Future<Result> setShuffle(bool on) => _run(Command.setShuffle(on), () => player.setShuffle(on));

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

  Future<void> _connected() async {
    if (!_restored) {
      _restored = true;
      await _restoreLastPlayback();
    }
    client!.sendState(player.report(full: true));
  }

  /// When the app opens and nothing plays, it shows where the music was (SPEC.md, "Last
  /// playback"): on its device, if that one is on; otherwise here, paused at the same point, so
  /// that play continues it.
  Future<void> _restoreLastPlayback() async {
    final hub = client!;
    final last = hub.lastPlayback;
    final queue = last?.state.queue;
    if (last == null || queue == null || queue.isEmpty) return;
    if (_whoIsPlaying() != null || player.queue.isNotEmpty) return;
    if (last.deviceId != hub.device.id && (hub.devices[last.deviceId]?.online ?? false)) {
      _active = last.deviceId;
      notifyListeners();
      return;
    }
    try {
      await player.obey(
        Command.setQueue(queue: queue, index: last.state.index ?? 0, positionMs: last.state.positionMs, play: false),
      );
    } on CommandFailed {
      // nothing in it can be played here
    }
  }

  void _update() {
    final playing = _whoIsPlaying();
    if (playing != null && playing != _playing) _active = playing == _here ? null : playing;
    _playing = playing;
    final active = activeDevice;
    if (_active != null && !(active?.online ?? false)) {
      _active = null; // gone or offline
      if (active != null) unawaited(_keepHere(active));
    }
    notifyListeners();
  }

  /// The device the app controlled went offline (closed, say): its music stays in the bar, here,
  /// paused where it got to, instead of vanishing with it.
  Future<void> _keepHere(Device device) async {
    final state = device.state;
    final queue = state?.queue;
    if (state == null || queue == null || queue.isEmpty) return;
    try {
      await player.obey(
        Command.setQueue(
          queue: queue,
          index: state.index ?? 0,
          positionMs: client!.positionMs(device.id) ?? state.positionMs,
          play: false,
        ),
      );
    } on CommandFailed {
      // nothing in it can be played here
    }
  }

  /// This device if it plays; otherwise the other device that reported playing most recently.
  String? _whoIsPlaying() {
    if (player.playing) return _here;
    Device? latest;
    for (final device in client?.devices.values ?? const <Device>[]) {
      final state = device.state;
      if (!device.online || state?.status != PlaybackStatus.playing) continue;
      if (latest == null || state!.at > latest.state!.at) latest = device;
    }
    return latest?.id;
  }

  @override
  void dispose() {
    player.removeListener(_update);
    client?.removeListener(_update);
    super.dispose();
  }
}
