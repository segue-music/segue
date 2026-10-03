import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segue/connect/connect.dart';
import 'package:segue/player/player.dart';
import 'package:segue/services.dart';
import 'package:segue/session.dart';
import 'package:segue/subsonic/api.dart';
import 'package:segue/subsonic/models.dart';
import 'package:segue/ui/shortcuts.dart';

import 'fakes.dart';

void main() {
  late PlayerController player;

  Future<void> pumpApp(WidgetTester tester, Widget page) async {
    const credentials = SubsonicCredentials(username: 'a', token: 't', salt: 's');
    final api = SubsonicApi(Uri.parse('https://music.test'), credentials);
    player = PlayerController(FakeEngine(), api);
    final services = Services(
      Session(server: Uri.parse('https://music.test'), credentials: credentials, deviceId: 'me', deviceName: 'me'),
      api,
      player,
      ConnectController(player: player),
    );
    await player.playQueue(const [Song(id: 's1', title: 'Dream On')]);
    // As in the app: services and shortcuts above the navigator, the page below.
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => ServicesScope(
          services: services,
          child: PlaybackShortcuts(child: child!),
        ),
        home: page,
      ),
    );
  }

  testWidgets('space plays and pauses, from any page', (tester) async {
    await pumpApp(tester, const Scaffold(body: Text('library')));
    expect(player.playing, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(player.playing, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(player.playing, isTrue);
  });

  testWidgets('space typed in a text field stays there', (tester) async {
    await pumpApp(tester, const Scaffold(body: TextField(autofocus: true)));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(player.playing, isTrue);
    FocusManager.instance.primaryFocus?.unfocus(); // done typing: space is play/pause again
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(player.playing, isFalse);
  });
}
