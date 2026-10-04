import 'dart:async';

import 'package:flutter/widgets.dart';

import 'connect/connect.dart';
import 'player/engine.dart';
import 'player/player.dart';
import 'segue/client.dart';
import 'segue/discovery.dart';
import 'segue/protocol.dart';
import 'server/server.dart';
import 'server/sign_in.dart';
import 'session.dart';

/// Everything a signed-in session runs on.
class Services {
  Services(this.session, this.api, this.player, this.connect);

  /// Starts a session: the API, this device's player and, if a hub is found, the connection to it.
  static Future<Services> start(Session session, {AudioEngine? engine}) async {
    final api = openServer(
      session.server,
      session.credentials,
      deviceId: session.deviceId,
      deviceName: session.deviceName,
    );
    final player = PlayerController(engine ?? MediaKitEngine(), api);
    final hubUrl = await discoverHub(session.server, hub: session.hub);
    final client = hubUrl == null
        ? null
        : SegueClient(
            url: hubUrl,
            auth: api.auth,
            device: DeviceInfo(
              id: session.deviceId,
              name: session.deviceName,
              client: clientName,
              version: appVersion,
              api: api.api,
              roles: Role.values,
              capabilities: CommandAction.values,
            ),
          );
    final services = Services(session, api, player, ConnectController(player: player, client: client));
    unawaited(client?.start());
    return services;
  }

  final Session session;
  final MediaServer api;
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
