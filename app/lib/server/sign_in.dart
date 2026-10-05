import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../jellyfin/api.dart';
import '../segue/protocol.dart';
import '../subsonic/api.dart';
import 'server.dart';

/// The address answers, but as neither a Subsonic nor a Jellyfin server.
class NotAMediaServer implements Exception {
  const NotAMediaServer(this.server);

  final Uri server;

  @override
  String toString() => '$server is neither a Subsonic nor a Jellyfin server';
}

/// Which API the media server at [server] speaks, so that the user only types its address: Subsonic
/// if it answers a ping (with an error, having no credentials), or else Jellyfin if it answers with
/// its public info. Navidrome, which has both, answers as Subsonic at its address and as Jellyfin
/// under /jellyfin. Throws [NotAMediaServer] when it answers as neither, and the failure itself
/// when it can't be asked. A ping that fails throws right away: Jellyfin is at the same address, so
/// asking it would only fail again, after another timeout.
Future<Api> detectApi(Uri server, {http.Client? client}) async {
  final httpClient = client ?? http.Client();
  final base = server.path.endsWith('/') ? server : server.replace(path: '${server.path}/');

  try {
    final ping = await _json(
      httpClient,
      base.resolve('rest/ping.view').replace(queryParameters: {'v': '1.16.1', 'c': clientName, 'f': 'json'}),
    );

    if (ping is Map && ping['subsonic-response'] is Map) {
      return Api.subsonic;
    }

    final info = await _json(httpClient, base.resolve('System/Info/Public'));

    if (info is Map && info['Id'] is String) {
      return Api.jellyfin;
    }
  } finally {
    if (client == null) {
      httpClient.close();
    }
  }

  throw NotAMediaServer(server);
}

/// An endpoint's JSON, or null when it isn't there (HTTP 4xx, or an answer that isn't JSON, like a
/// web page). Throws on what may go away: no network, HTTP 5xx.
Future<Object?> _json(http.Client client, Uri url) async {
  final response = await client.get(url).timeout(const Duration(seconds: 10));

  if (response.statusCode >= 400 && response.statusCode < 500) {
    return null;
  }

  if (response.statusCode != 200) {
    throw ServerError('${url.host}: HTTP ${response.statusCode}');
  }

  try {
    return jsonDecode(utf8.decode(response.bodyBytes));
  } on FormatException {
    return null;
  }
}

/// Signs in to the media server at [server], in whichever API it speaks ([detectApi]). Jellyfin
/// keeps a sign-in per device, so it learns this one's [deviceId] and [deviceName].
Future<MediaServer> signIn(
  Uri server,
  String username,
  String password, {
  required String deviceId,
  required String deviceName,
  http.Client? client,
}) async {
  switch (await detectApi(server, client: client)) {
    case Api.subsonic:
      final api = SubsonicApi(server, SubsonicCredentials.fromPassword(username, password), client: client);

      try {
        await api.ping();
        return api;
      } on Object {
        if (client == null) {
          api.close();
        }

        rethrow;
      }
    case Api.jellyfin:
      return JellyfinApi.signIn(server, username, password, deviceId: deviceId, deviceName: deviceName, client: client);
  }
}

/// The media server of a saved sign-in, in the API the credentials are for.
MediaServer openServer(Uri server, Credentials credentials, {required String deviceId, required String deviceName}) =>
    switch (credentials) {
      SubsonicCredentials() => SubsonicApi(server, credentials),
      JellyfinCredentials() => JellyfinApi(server, credentials, deviceId: deviceId, deviceName: deviceName),
      _ => throw ArgumentError.value(credentials, 'credentials', 'neither Subsonic nor Jellyfin'),
    };
