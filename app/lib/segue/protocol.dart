// Wire format of the Segue protocol, version 1 (draft). SPEC.md explains the semantics; the hub's
// side of the same types is hub/protocol.go.

import 'dart:math';

const protocolVersion = 1;

enum Api { subsonic, jellyfin }

enum Role { player, controller }

enum PlaybackStatus { playing, paused, stopped }

/// The command names. Their `name` is the wire name.
enum CommandAction { play, pause, toggle, stop, next, previous, jump, seek, setVolume, setQueue, setRepeat, setShuffle }

/// A player's repeat mode (SPEC.md, section 4). Their `name` is the wire name.
enum Repeat { off, all, one }

/// Close codes (SPEC.md, section 2).
abstract final class CloseCode {
  static const unauthorized = 4001;
  static const badHello = 4002;
  static const replaced = 4003;
  static const unavailable = 1011;
}

T _enum<T extends Enum>(List<T> values, Object? name) => values.firstWhere((v) => v.name == name);

/// The credentials the app already uses with the media server.
class Auth {
  const Auth.subsonic({required String this.username, required String this.token, required String this.salt})
    : scheme = 'subsonic',
      apiKey = null;

  /// A Jellyfin access token, which the hub checks with /Users/Me.
  const Auth.jellyfin({required String this.token}) : scheme = 'jellyfin', username = null, salt = null, apiKey = null;

  final String scheme;
  final String? username;
  final String? token;
  final String? salt;
  final String? apiKey;

  Map<String, Object?> toJson() => {
    'scheme': scheme,
    'username': ?username,
    'token': ?token,
    'salt': ?salt,
    'apiKey': ?apiKey,
  };
}

class QueueItem {
  const QueueItem({this.id, this.title, this.artist, this.album, this.durationMs});

  factory QueueItem.fromJson(Map<String, dynamic> json) => QueueItem(
    id: json['id'] as String?,
    title: json['title'] as String?,
    artist: json['artist'] as String?,
    album: json['album'] as String?,
    durationMs: (json['durationMs'] as num?)?.toInt(),
  );

  /// The media server's id, in this device's API. Null when the hub couldn't translate it.
  final String? id;
  final String? title;
  final String? artist;
  final String? album;
  final int? durationMs;

  Map<String, Object?> toJson() => {
    'id': ?id,
    'title': ?title,
    'artist': ?artist,
    'album': ?album,
    'durationMs': ?durationMs,
  };
}

/// What a player reports. [status] and [positionMs] go in every report; an optional field left
/// null keeps its previous value.
class PlayerState {
  const PlayerState({
    required this.status,
    required this.positionMs,
    this.queue,
    this.index,
    this.volume,
    this.repeat,
    this.shuffle,
  });

  final PlaybackStatus status;
  final int positionMs;
  final List<QueueItem>? queue;
  final int? index;
  final int? volume;
  final Repeat? repeat;

  /// Whether [queue] is in a shuffled order.
  final bool? shuffle;

  Map<String, Object?> toJson() => {
    'status': status.name,
    'positionMs': positionMs,
    'queue': ?queue?.map((item) => item.toJson()).toList(),
    'index': ?index,
    'volume': ?volume,
    'repeat': ?repeat?.name,
    'shuffle': ?shuffle,
  };
}

/// A state as the hub relays it: [at] is the hub time (epoch ms) at which [positionMs] held.
class StampedState extends PlayerState {
  const StampedState({
    required super.status,
    required super.positionMs,
    required this.at,
    super.queue,
    super.index,
    super.volume,
    super.repeat,
    super.shuffle,
  });

  factory StampedState.fromJson(Map<String, dynamic> json) => StampedState(
    status: _enum(PlaybackStatus.values, json['status']),
    positionMs: (json['positionMs'] as num).toInt(),
    at: (json['at'] as num).toInt(),
    queue: (json['queue'] as List?)?.map((item) => QueueItem.fromJson(item as Map<String, dynamic>)).toList(),
    index: (json['index'] as num?)?.toInt(),
    volume: (json['volume'] as num?)?.toInt(),
    repeat: json['repeat'] == null ? null : _enum(Repeat.values, json['repeat']),
    shuffle: json['shuffle'] as bool?,
  );

  final int at;

  /// This state with a report from the hub applied over it.
  StampedState merge(StampedState report) => StampedState(
    status: report.status,
    positionMs: report.positionMs,
    at: report.at,
    queue: report.queue ?? queue,
    index: report.index ?? index,
    volume: report.volume ?? volume,
    repeat: report.repeat ?? repeat,
    shuffle: report.shuffle ?? shuffle,
  );

  QueueItem? get current {
    final i = index ?? 0;
    return queue != null && i < queue!.length ? queue![i] : null;
  }

  /// Where playback is at hub time [now] (epoch ms), extrapolated from the last report.
  int positionAt(int now) {
    if (status != PlaybackStatus.playing) return positionMs;
    final position = positionMs + max<int>(0, now - at);
    final duration = current?.durationMs;
    return duration == null || duration <= 0 ? position : min<int>(position, duration);
  }
}

class Command {
  const Command(this.action)
    : positionMs = null,
      volume = null,
      queue = null,
      index = null,
      play = null,
      repeat = null,
      shuffle = null;

  const Command.jump(int this.index)
    : action = CommandAction.jump,
      positionMs = null,
      volume = null,
      queue = null,
      play = null,
      repeat = null,
      shuffle = null;

  const Command.seek(int this.positionMs)
    : action = CommandAction.seek,
      volume = null,
      queue = null,
      index = null,
      play = null,
      repeat = null,
      shuffle = null;

  const Command.setVolume(int this.volume)
    : action = CommandAction.setVolume,
      positionMs = null,
      queue = null,
      index = null,
      play = null,
      repeat = null,
      shuffle = null;

  const Command.setQueue({
    required List<QueueItem> this.queue,
    required int this.index,
    required int this.positionMs,
    required bool this.play,
  }) : action = CommandAction.setQueue,
       volume = null,
       repeat = null,
       shuffle = null;

  const Command.setRepeat(Repeat this.repeat)
    : action = CommandAction.setRepeat,
      positionMs = null,
      volume = null,
      queue = null,
      index = null,
      play = null,
      shuffle = null;

  const Command.setShuffle(bool this.shuffle)
    : action = CommandAction.setShuffle,
      positionMs = null,
      volume = null,
      queue = null,
      index = null,
      play = null,
      repeat = null;

  factory Command.fromJson(Map<String, dynamic> json) {
    final action = _enum(CommandAction.values, json['action']);
    return switch (action) {
      CommandAction.jump => Command.jump((json['index'] as num).toInt()),
      CommandAction.seek => Command.seek((json['positionMs'] as num).toInt()),
      CommandAction.setVolume => Command.setVolume((json['volume'] as num).toInt()),
      CommandAction.setQueue => Command.setQueue(
        queue: (json['queue'] as List).map((item) => QueueItem.fromJson(item as Map<String, dynamic>)).toList(),
        index: (json['index'] as num).toInt(),
        positionMs: (json['positionMs'] as num).toInt(),
        play: json['play'] as bool,
      ),
      CommandAction.setRepeat => Command.setRepeat(_enum(Repeat.values, json['repeat'])),
      CommandAction.setShuffle => Command.setShuffle(json['shuffle'] as bool),
      _ => Command(action),
    };
  }

  final CommandAction action;
  final int? positionMs;
  final int? volume;
  final List<QueueItem>? queue;
  final int? index;
  final bool? play;
  final Repeat? repeat;
  final bool? shuffle;

  Map<String, Object?> toJson() => {
    'action': action.name,
    'positionMs': ?positionMs,
    'volume': ?volume,
    'queue': ?queue?.map((item) => item.toJson()).toList(),
    'index': ?index,
    'play': ?play,
    'repeat': ?repeat?.name,
    'shuffle': ?shuffle,
  };
}

class DeviceInfo {
  const DeviceInfo({
    required this.id,
    required this.name,
    required this.client,
    required this.api,
    required this.roles,
    required this.capabilities,
    this.version,
  });

  factory DeviceInfo.fromJson(Map<String, dynamic> json) => DeviceInfo(
    id: json['id'] as String,
    name: json['name'] as String,
    client: json['client'] as String,
    version: json['version'] as String?,
    api: _enum(Api.values, json['api']),
    roles: [for (final r in json['roles'] as List) _enum(Role.values, r)],
    // Commands this app doesn't know are left out (SPEC.md, section 2).
    capabilities: [
      for (final a in json['capabilities'] as List) ...CommandAction.values.where((known) => known.name == a),
    ],
  );

  /// Stable per installation, not per connection.
  final String id;
  final String name;
  final String client;
  final String? version;
  final Api api;
  final List<Role> roles;

  /// The commands this device obeys as a player.
  final List<CommandAction> capabilities;

  bool get isPlayer => roles.contains(Role.player);

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'client': client,
    'version': ?version,
    'api': api.name,
    'roles': [for (final r in roles) r.name],
    'capabilities': [for (final a in capabilities) a.name],
  };
}

/// Another device of the same user, as the hub describes it.
class Device {
  Device({required this.info, required this.online, this.state});

  factory Device.fromJson(Map<String, dynamic> json) => Device(
    info: DeviceInfo.fromJson(json),
    online: json['online'] as bool,
    state: json['state'] == null ? null : StampedState.fromJson(json['state'] as Map<String, dynamic>),
  );

  final DeviceInfo info;
  final bool online;
  StampedState? state;

  String get id => info.id;
}

/// The user's most recent playback, as the hub keeps it across app restarts (SPEC.md, "Last
/// playback"): the queue is already in this device's API.
class LastPlayback {
  const LastPlayback({required this.deviceId, required this.deviceName, required this.state});

  factory LastPlayback.fromJson(Map<String, dynamic> json) => LastPlayback(
    deviceId: json['deviceId'] as String,
    deviceName: json['deviceName'] as String,
    state: StampedState.fromJson(json['state'] as Map<String, dynamic>),
  );

  /// The device that holds it (possibly this one): the one that played it, until it went offline.
  /// Empty after that, until a device plays; [deviceName] still says where it played.
  final String deviceId;
  final String deviceName;
  final StampedState state;
}

/// The answer to a command or a transfer.
class Result {
  const Result({required this.ok, this.error});

  final bool ok;

  /// One of the hub's error names (SPEC.md, section 5), or the player's own text.
  final String? error;
}
