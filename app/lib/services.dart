import 'dart:async';

import 'package:flutter/widgets.dart';

import 'connect/connect.dart';
import 'player/engine.dart';
import 'player/player.dart';
import 'segue/client.dart';
import 'segue/discovery.dart';
import 'segue/protocol.dart';
import 'session.dart';
import 'subsonic/api.dart';

const appVersion = '0.1.0';

/// Everything a signed-in session runs on.
class Services {
  Services._(this.session, this.api, this.player, this.connect);

  /// Starts a session: the API, this device's player and, if a hub is found, the connection to it.
  static Future<Services> start(Session session, {AudioEngine? engine}) async {
    final api = SubsonicApi(session.server, session.credentials);
    final player = PlayerController(engine ?? MediaKitEngine(), api);
    final hubUrl = await discoverHub(session.server, hub: session.hub);
    final client = hubUrl == null
        ? null
        : SegueClient(
            url: hubUrl,
            auth: Auth.subsonic(
              username: session.credentials.username,
              token: session.credentials.token,
              salt: session.credentials.salt,
            ),
            device: DeviceInfo(
              id: session.deviceId,
              name: session.deviceName,
              client: SubsonicApi.clientName,
              version: appVersion,
              api: Api.subsonic,
              roles: Role.values,
              capabilities: CommandAction.values,
            ),
          );
    final services = Services._(session, api, player, ConnectController(player: player, client: client));
    unawaited(client?.start());
    return services;
  }

  final Session session;
  final SubsonicApi api;
  final PlayerController player;
  final ConnectController connect;

  Future<void> dispose() async {
    connect.dispose();
    await connect.client?.close();
    await player.dispose();
    api.close();
  }
}

/// Hands [Services] down the widget tree.
class ServicesScope extends InheritedWidget {
  const ServicesScope({required this.services, required super.child, super.key});

  final Services services;

  static Services of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<ServicesScope>()!.services;

  @override
  bool updateShouldNotify(ServicesScope oldWidget) => services != oldWidget.services;
}
