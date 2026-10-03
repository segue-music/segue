import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'subsonic/api.dart';

/// Who is signed in, where, and as which device. The token and salt are as good as the password
/// on that server, so they go to the system's secure storage; the rest to plain preferences.
class Session {
  const Session({
    required this.server,
    required this.credentials,
    required this.deviceId,
    required this.deviceName,
    this.hub,
  });

  final Uri server;
  final SubsonicCredentials credentials;

  /// Stable for this installation: the hub knows the device by it.
  final String deviceId;
  final String deviceName;

  /// The hub's address, when the user typed one; otherwise it is looked for next to [server].
  final Uri? hub;

  static const _secure = FlutterSecureStorage();
  static final _prefs = SharedPreferencesAsync();

  /// The saved session, or null: none saved, or the secure storage can't be read (no keyring
  /// running), which just means signing in again.
  static Future<Session?> load() async {
    final server = await _prefs.getString('server');
    final username = await _prefs.getString('username');
    final String? token, salt;
    try {
      token = await _secure.read(key: 'token');
      salt = await _secure.read(key: 'salt');
    } on Exception catch (e) {
      debugPrint('secure storage unavailable: $e');
      return null;
    }
    if (server == null || username == null || token == null || salt == null) return null;
    final hub = await _prefs.getString('hub');
    return Session(
      server: Uri.parse(server),
      credentials: SubsonicCredentials(username: username, token: token, salt: salt),
      deviceId: _env('SEGUE_DEVICE_ID') ?? await deviceIdOfThisInstallation(),
      deviceName: _env('SEGUE_DEVICE_NAME') ?? await _prefs.getString('deviceName') ?? defaultDeviceName(),
      hub: hub == null ? null : Uri.parse(hub),
    );
  }

  Future<void> save() async {
    await _prefs.setString('server', server.toString());
    await _prefs.setString('username', credentials.username);
    await _prefs.setString('deviceName', deviceName);
    if (hub == null) {
      await _prefs.remove('hub');
    } else {
      await _prefs.setString('hub', hub.toString());
    }
    await _secure.write(key: 'token', value: credentials.token);
    await _secure.write(key: 'salt', value: credentials.salt);
  }

  /// Signs out. The device id stays: it is this installation's, not the session's.
  static Future<void> clear() async {
    await _secure.delete(key: 'token');
    await _secure.delete(key: 'salt');
    await _prefs.remove('username');
  }

  static Future<String> deviceIdOfThisInstallation() async {
    final existing = await _prefs.getString('deviceId');
    if (existing != null) return existing;
    final id = const Uuid().v4();
    await _prefs.setString('deviceId', id);
    return id;
  }

  /// SEGUE_DEVICE_ID and SEGUE_DEVICE_NAME let two copies of the app on one computer be two
  /// devices, for trying Connect out.
  static String? _env(String name) => Platform.environment[name];

  static String defaultDeviceName() {
    if (Platform.isAndroid) return 'Android';
    if (Platform.isIOS) return 'iPhone';
    return Platform.localHostname;
  }
}

/// What the user typed as the server, as a URL: https unless they said otherwise.
Uri normalizeServer(String input) {
  final text = input.trim();
  return Uri.parse(text.contains('://') ? text : 'https://$text');
}
