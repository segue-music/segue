import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segue/jellyfin/api.dart';
import 'package:segue/server/server.dart';
import 'package:segue/session.dart';
import 'package:segue/subsonic/api.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  final prefs = InMemorySharedPreferencesAsync.empty();
  setUpAll(() => SharedPreferencesAsyncPlatform.instance = prefs);
  setUp(() async {
    await SharedPreferencesAsync().clear();
    await SharedPreferencesAsync().setString('deviceId', 'd1');
    await SharedPreferencesAsync().setString('deviceName', 'laptop');
    FlutterSecureStorage.setMockInitialValues({});
  });

  Session session(Credentials credentials) =>
      Session(server: Uri.parse('https://music.test'), credentials: credentials, deviceId: 'd1', deviceName: 'laptop');

  test('a Jellyfin sign-in comes back as it was saved, its token in the secure storage', () async {
    await session(const JellyfinCredentials(username: 'alice', userId: 'u1', token: 't1')).save();
    expect(await const FlutterSecureStorage().read(key: 'token'), 't1');
    final loaded = await Session.load();
    expect(loaded?.server, Uri.parse('https://music.test'));
    final credentials = loaded?.credentials as JellyfinCredentials;
    expect((credentials.username, credentials.userId, credentials.token), ('alice', 'u1', 't1'));
  });

  test('a Subsonic sign-in comes back as it was saved', () async {
    await session(const SubsonicCredentials(username: 'alice', token: 't', salt: 's')).save();
    final credentials = (await Session.load())?.credentials as SubsonicCredentials;
    expect((credentials.username, credentials.token, credentials.salt), ('alice', 't', 's'));
  });

  test('a sign-in saved before Jellyfin came is a Subsonic one', () async {
    await SharedPreferencesAsync().setString('server', 'https://music.test');
    await SharedPreferencesAsync().setString('username', 'alice');
    FlutterSecureStorage.setMockInitialValues({'token': 't', 'salt': 's'});
    final credentials = (await Session.load())?.credentials;
    expect(credentials, isA<SubsonicCredentials>().having((c) => c.token, 'token', 't'));
  });

  test('signing out forgets the sign-in, not the device', () async {
    await session(const JellyfinCredentials(username: 'alice', userId: 'u1', token: 't1')).save();
    await Session.clear();
    expect(await Session.load(), isNull);
    expect(await const FlutterSecureStorage().read(key: 'token'), isNull);
    expect(await Session.thisDeviceId(), 'd1');
  });
}
