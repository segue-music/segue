import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:segue/connect/connect.dart';
import 'package:segue/player/player.dart';
import 'package:segue/segue/client.dart';
import 'package:segue/segue/protocol.dart';
import 'package:segue/services.dart';
import 'package:segue/session.dart';
import 'package:segue/subsonic/api.dart';
import 'package:segue/ui/devices_sheet.dart';

import 'fakes.dart';

Device player(String id, String name, {required bool online}) => Device(
  info: DeviceInfo(
    id: id,
    name: name,
    client: 'test',
    api: Api.subsonic,
    roles: const [Role.player],
    capabilities: const [],
  ),
  online: online,
);

/// Opens the device picker with [devices] as the user's other devices.
Future<void> openSheet(WidgetTester tester, List<Device> devices) async {
  const credentials = SubsonicCredentials(username: 'a', token: 't', salt: 's');
  final api = SubsonicApi(
    Uri.parse('https://music.test'),
    credentials,
    client: MockClient((_) async => http.Response('', 404)),
  );
  final client = SegueClient(
    url: Uri.parse('ws://unused'),
    auth: const Auth.subsonic(username: 'a', token: 't', salt: 's'),
    device: const DeviceInfo(id: 'me', name: 'me', client: 'test', api: Api.subsonic, roles: [], capabilities: []),
  );

  for (final device in devices) {
    client.devices[device.id] = device;
  }

  final player = PlayerController(FakeEngine(), api);
  final services = Services(
    Session(server: Uri.parse('https://music.test'), credentials: credentials, deviceId: 'me', deviceName: 'Notebook'),
    api,
    player,
    ConnectController(player: player, client: client),
  );
  await tester.pumpWidget(
    MaterialApp(
      // Above the navigator, as in the app, so that the sheet sees it.
      builder: (context, child) => ServicesScope(services: services, child: child!),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(onPressed: () => showDevicesSheet(context), child: const Text('abrir')),
        ),
      ),
    ),
  );
  await tester.tap(find.text('abrir'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the picker lists only the devices that are online', (tester) async {
    await openSheet(tester, [
      player('tv', 'Sala de estar', online: true),
      player('old', 'Celular antigo', online: false),
    ]);
    expect(find.text('Este aparelho (Notebook)'), findsOneWidget);
    expect(find.text('Sala de estar'), findsOneWidget);
    expect(find.text('Celular antigo'), findsNothing);
  });
}
