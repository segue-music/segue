import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segue/connect/connect.dart';
import 'package:segue/player/player.dart';
import 'package:segue/server/models.dart';
import 'package:segue/services.dart';
import 'package:segue/session.dart';
import 'package:segue/subsonic/api.dart';
import 'package:segue/ui/shortcuts.dart';

import 'fakes.dart';

void main() {
  late PlayerController player;

  Future<void> pumpApp(WidgetTester tester, Widget page, {bool mediaKeys = false}) async {
    const credentials = SubsonicCredentials(username: 'a', token: 't', salt: 's');
    final api = SubsonicApi(Uri.parse('https://music.test'), credentials);
    player = PlayerController(FakeEngine(), api);
    final services = Services(
      Session(server: Uri.parse('https://music.test'), credentials: credentials, deviceId: 'me', deviceName: 'me'),
      api,
      player,
      ConnectController(player: player),
    );
    await player.playQueue(const [Song(id: 's1', title: 'Dream On'), Song(id: 's2', title: 'Other')]);
    // As in the app: services and shortcuts above the navigator, the page below.
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => ServicesScope(
          services: services,
          child: PlaybackShortcuts(mediaKeys: mediaKeys, child: child!),
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

  testWidgets('where they come as keys, the media keys play, pause and skip, even while typing', (tester) async {
    await pumpApp(tester, const Scaffold(body: TextField(autofocus: true)), mediaKeys: true);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.mediaPlayPause);
    await tester.pump();
    expect(player.playing, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.mediaPlayPause);
    await tester.pump();
    expect(player.playing, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.mediaTrackNext);
    await tester.pump();
    expect(player.index, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.mediaTrackPrevious);
    await tester.pump();
    expect(player.index, 0);
  });

  testWidgets('where a system media session takes the media keys, the app leaves them to it', (tester) async {
    await pumpApp(tester, const Scaffold(body: Text('library')));
    await tester.sendKeyEvent(LogicalKeyboardKey.mediaPlayPause);
    await tester.pump();
    expect(player.playing, isTrue);
  });
}
