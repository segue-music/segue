import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'protocol.dart';

/// Obeys a command from another device. Throwing [CommandFailed] reports it as failed.
typedef CommandHandler = Future<void> Function(Command command, String from);

/// A command this device can't carry out; [message] goes back to the device that sent it.
class CommandFailed implements Exception {
  const CommandFailed(this.message);

  final String message;

  @override
  String toString() => message;
}

enum HubStatus { connecting, connected, offline, rejected }

/// The hub closed the connection before accepting the device.
class HubClosed implements Exception {
  const HubClosed(this.code, this.reason);

  final int? code;
  final String? reason;

  /// Retrying won't help: wrong credentials, a bad hello, or the device connected elsewhere.
  bool get isFinal => code == CloseCode.unauthorized || code == CloseCode.badHello || code == CloseCode.replaced;

  @override
  String toString() => 'hub closed the connection: $code $reason';
}

/// Talks to the hub for this device: keeps the user's other devices up to date, reports this
/// player's state and obeys commands. [start] keeps it connected; [connect] is a single attempt.
class SegueClient extends ChangeNotifier {
  SegueClient({
    required this.url,
    required this.auth,
    required this.device,
    this.onCommand,
    this.onConnected,
    WebSocketChannel Function(Uri url)? channelFactory,
  }) : _channelFactory = channelFactory ?? WebSocketChannel.connect;

  /// The hub's WebSocket URL.
  final Uri url;
  final Auth auth;
  final DeviceInfo device;
  CommandHandler? onCommand;

  /// Called after every (re)connection, e.g. to report the full state again.
  VoidCallback? onConnected;

  /// The user's other devices, by id.
  final devices = <String, Device>{};
  HubStatus status = HubStatus.offline;

  final WebSocketChannel Function(Uri url) _channelFactory;
  WebSocketChannel? _channel;
  bool _open = false;
  Completer<void>? _ended;
  final _waiting = <String, Completer<Result>>{};
  int _seq = 0;
  int _clockOffset = 0; // hub time minus local time
  bool _running = false;

  /// Hub time now, in epoch ms.
  int get hubNow => DateTime.now().millisecondsSinceEpoch + _clockOffset;

  /// Connects and keeps reconnecting, with backoff, until [close] or a final rejection.
  Future<void> start() async {
    _running = true;
    var backoff = const Duration(seconds: 1);
    while (_running) {
      _setStatus(HubStatus.connecting);
      try {
        await connect();
        backoff = const Duration(seconds: 1);
        await closed;
      } on HubClosed catch (e) {
        if (e.isFinal) {
          _running = false;
          _setStatus(HubStatus.rejected);
          return;
        }
      } catch (_) {
        // network error: retry below
      }
      if (!_running) break;
      _setStatus(HubStatus.offline);
      await Future<void>.delayed(backoff);
      backoff = Duration(milliseconds: min(backoff.inMilliseconds * 2, 30000));
    }
    _setStatus(HubStatus.offline);
  }

  /// Completes when the current connection ends.
  Future<void> get closed => _ended?.future ?? Future.value();

  /// Opens one connection. Completes once the hub has accepted the device; throws [HubClosed] if
  /// the hub refuses it.
  Future<void> connect() async {
    final channel = _channelFactory(url);
    _channel = channel;
    await channel.ready;
    _open = true;
    final welcomed = Completer<void>();
    final ended = _ended = Completer<void>();
    channel.stream.listen(
      (data) {
        final msg = jsonDecode(data as String) as Map<String, dynamic>;
        _receive(msg);
        if (msg['type'] == 'welcome' && !welcomed.isCompleted) welcomed.complete();
      },
      onDone: () {
        _open = false;
        for (final waiting in _waiting.values) {
          waiting.complete(const Result(ok: false, error: 'closed'));
        }
        _waiting.clear();
        if (welcomed.isCompleted) {
          _setStatus(HubStatus.offline);
        } else {
          welcomed.completeError(HubClosed(channel.closeCode, channel.closeReason));
        }
        ended.complete();
      },
      onError: (_) {}, // onDone follows
    );
    _send({'type': 'hello', 'protocol': protocolVersion, 'auth': auth.toJson(), 'device': device.toJson()});
    await welcomed.future;
    _setStatus(HubStatus.connected);
    onConnected?.call();
  }

  Future<void> close() async {
    _running = false;
    await _channel?.sink.close(1000);
  }

  /// Reports this device's playback. Send it on every change; the hub stamps the time.
  void sendState(PlayerState state) => _send({'type': 'state', 'state': state.toJson()});

  Future<Result> command(String target, Command command) =>
      _ask({'type': 'command', 'target': target, 'command': command.toJson()});

  /// Moves [from]'s queue, at its current position, to [to] (often this device: "continue here").
  Future<Result> transfer(String from, String to, {bool play = true}) =>
      _ask({'type': 'transfer', 'from': from, 'to': to, 'play': play});

  /// Where a device's playback is now.
  int? positionMs(String deviceId) => devices[deviceId]?.state?.positionAt(hubNow);

  void _receive(Map<String, dynamic> msg) {
    switch (msg['type']) {
      case 'welcome':
        _clockOffset = (msg['serverTime'] as num).toInt() - DateTime.now().millisecondsSinceEpoch;
        devices
          ..clear()
          ..addEntries(
            [for (final d in msg['devices'] as List) Device.fromJson(d as Map<String, dynamic>)]
                .map((d) => MapEntry(d.id, d)),
          );
      case 'device':
        final device = Device.fromJson(msg['device'] as Map<String, dynamic>);
        devices[device.id] = device;
      case 'state':
        final device = devices[msg['deviceId']];
        final report = StampedState.fromJson(msg['state'] as Map<String, dynamic>);
        if (device != null) device.state = device.state?.merge(report) ?? report;
      case 'gone':
        devices.remove(msg['deviceId']);
      case 'command':
        unawaited(
          _obey(msg['id'] as String, Command.fromJson(msg['command'] as Map<String, dynamic>), msg['from'] as String),
        );
        return;
      case 'result':
        _waiting.remove(msg['re'])?.complete(Result(ok: msg['ok'] as bool, error: msg['error'] as String?));
        return;
      default:
        return;
    }
    notifyListeners();
  }

  Future<void> _obey(String id, Command command, String from) async {
    try {
      final handler = onCommand;
      if (handler == null) throw const CommandFailed('unsupported');
      await handler(command, from);
      _send({'type': 'result', 're': id, 'ok': true});
    } catch (e) {
      _send({'type': 'result', 're': id, 'ok': false, 'error': '$e'});
    }
  }

  Future<Result> _ask(Map<String, Object?> msg) {
    if (!_open || status != HubStatus.connected) return Future.value(const Result(ok: false, error: 'closed'));
    final id = 'r${++_seq}';
    final answer = Completer<Result>();
    _waiting[id] = answer;
    _send({...msg, 'id': id});
    return answer.future;
  }

  void _send(Map<String, Object?> msg) {
    if (_open) _channel!.sink.add(jsonEncode(msg));
  }

  void _setStatus(HubStatus value) {
    if (status == value) return;
    status = value;
    notifyListeners();
  }
}
