import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'package:segue/subsonic/models.dart';
import 'package:segue/ui/home_page.dart';
import 'package:segue/ui/now_playing_bar.dart';
import 'package:segue/ui/shortcuts.dart';

import 'fakes.dart';

/// The player bar, with a song at 1:00, and the focus on its slider. [television] as on a TV.
Future<PlayerController> pumpBarOnSlider(
  WidgetTester tester, {
  required bool television,
  Widget body = const SizedBox.expand(),
}) async {
  const credentials = SubsonicCredentials(username: 'a', token: 't', salt: 's');
  final api = SubsonicApi(
    Uri.parse('https://music.test'),
    credentials,
    client: MockClient((_) async => http.Response('', 404)),
  );
  final player = PlayerController(FakeEngine(), api);
  await player.playQueue(
    const [Song(id: 's1', title: 'Dream On', duration: Duration(minutes: 4))],
    position: const Duration(minutes: 1),
    play: false,
  );
  final services = Services(
    Session(server: Uri.parse('https://music.test'), credentials: credentials, deviceId: 'me', deviceName: 'me'),
    api,
    player,
    ConnectController(player: player),
  );
  tester.view.physicalSize = const Size(1000, 600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => ServicesScope(
        services: services,
        child: DirectionalNavigation(enabled: television, child: child!),
      ),
      home: Scaffold(body: body, bottomNavigationBar: const NowPlayingBar()),
    ),
  );
  for (var i = 0; i < 100 && !sliderFocused(); i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
  }
  return player;
}

bool sliderFocused() => FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<Slider>() != null;

/// The home page on a TV-sized screen, with more albums than fit, and a song in the bar: the grid
/// builds the next row past the bottom of the screen, under the bar.
Future<void> pumpTvHome(WidgetTester tester, {bool followingAnotherDevice = false}) async {
  const credentials = SubsonicCredentials(username: 'a', token: 't', salt: 's');
  final api = SubsonicApi(
    Uri.parse('https://music.test'),
    credentials,
    client: MockClient((request) async {
      if (!request.url.path.endsWith('getAlbumList2.view')) return http.Response('', 404);
      final albums = [for (var i = 0; i < 30; i++) '{"id": "a$i", "name": "Album $i"}'].join(',');
      return http.Response(
        '{"subsonic-response": {"status": "ok", "albumList2": {"album": [$albums]}}}',
        200,
        headers: {'content-type': 'application/json'},
      );
    }),
  );
  final player = PlayerController(FakeEngine(), api);
  await player.playQueue(const [Song(id: 's1', title: 'Dream On', duration: Duration(minutes: 4))], play: false);
  final client = followingAnotherDevice ? _anotherDevicePlaying() : null;
  final connect = ConnectController(player: player, client: client);
  // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
  client?.notifyListeners(); // as when the other device's state arrives
  final services = Services(
    Session(server: Uri.parse('https://music.test'), credentials: credentials, deviceId: 'me', deviceName: 'me'),
    api,
    player,
    connect,
  );
  tester.view.physicalSize = const Size(1920, 1080);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => ServicesScope(
        services: services,
        child: DirectionalNavigation(enabled: true, child: TextFieldArrowShortcuts(child: child!)),
      ),
      home: HomePage(onSignOut: () {}),
    ),
  );
  await tester.pumpAndSettle();
}

/// A hub client that sees another device play: the app follows it, and the bar gets the "Tocando
/// em" strip under it, which makes it taller.
SegueClient _anotherDevicePlaying() {
  final client = SegueClient(
    url: Uri.parse('ws://unused'),
    auth: const Auth.subsonic(username: 'a', token: 't', salt: 's'),
    device: const DeviceInfo(id: 'me', name: 'me', client: 'test', api: Api.subsonic, roles: [], capabilities: []),
  );
  client.devices['desktop'] = Device(
    info: const DeviceInfo(
      id: 'desktop',
      name: 'desktop',
      client: 'test',
      api: Api.subsonic,
      roles: [Role.player],
      capabilities: CommandAction.values,
    ),
    online: true,
    state: StampedState(
      status: PlaybackStatus.playing,
      positionMs: 30000,
      at: DateTime.now().millisecondsSinceEpoch,
      index: 0,
      repeat: Repeat.all,
      queue: const [QueueItem(id: 's1', title: 'Dream On', artist: 'Aerosmith', durationMs: 240000)],
    ),
  );
  return client;
}

bool inBar() => FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<NowPlayingBar>() != null;

/// The tooltip of what has the focus: a button's, or the song's ("Abrir o player").
String? focusedTip() {
  final context = FocusManager.instance.primaryFocus?.context;
  return context?.findAncestorWidgetOfExactType<IconButton>()?.tooltip ??
      context?.findAncestorWidgetOfExactType<Tooltip>()?.message;
}

Future<void> tabTo(WidgetTester tester, bool Function() there) async {
  for (var i = 0; i < 100 && !there(); i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
  }
  expect(there(), isTrue);
}

/// Like [tabTo], backwards: from the end of the screen, the bar, without passing through the grid,
/// which a Tab would scroll to line its rows up.
Future<void> shiftTabTo(WidgetTester tester, bool Function() there) async {
  for (var i = 0; i < 100 && !there(); i++) {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
  }
  expect(there(), isTrue);
}

Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('on a TV, down from the slider goes to the buttons, without moving the song', (tester) async {
    final player = await pumpBarOnSlider(tester, television: true);
    expect(sliderFocused(), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(player.position, const Duration(minutes: 1));
    expect(sliderFocused(), isFalse);
    // Left and right still move it.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(sliderFocused(), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(player.position, greaterThan(const Duration(minutes: 1)));
    await tester.pumpWidget(const SizedBox()); // stops the bar's timers
  });

  testWidgets('elsewhere, the arrows keep moving a focused slider, as they do on a computer', (tester) async {
    final player = await pumpBarOnSlider(tester, television: false);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(player.position, lessThan(const Duration(minutes: 1)));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the bar is the floor: down from its last row stays there, not in the albums under it', (tester) async {
    await pumpTvHome(tester);
    await tabTo(tester, sliderFocused);
    await press(tester, LogicalKeyboardKey.arrowDown); // to the bar's last row
    expect(inBar() && !sliderFocused(), isTrue);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(inBar(), isTrue, reason: 'still in the bar');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('in the bar, right goes along the buttons to the last one, and stops there', (tester) async {
    await pumpTvHome(tester);
    await tabTo(tester, () => focusedTip() == 'Próxima');
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focusedTip(), 'Repetir a lista');
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focusedTip(), 'Fila');
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focusedTip(), 'Aparelhos');
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focusedTip(), 'Aparelhos', reason: 'the last one: not to the albums under the bar');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('right from "Próxima" stays in the bar with an album row cut by it, as the grid scrolls', (tester) async {
    // As the grid first shows: its second row goes on under the bar, level with the buttons.
    await pumpTvHome(tester, followingAnotherDevice: true);
    await shiftTabTo(tester, () => focusedTip() == 'Próxima');
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focusedTip(), 'Repetir a faixa', reason: 'not the album under the bar');
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focusedTip(), 'Fila');
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focusedTip(), 'Aparelhos');
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focusedTip(), 'Aparelhos');
    for (var i = 0; i < 4; i++) {
      await press(tester, LogicalKeyboardKey.arrowLeft);
    }
    expect(focusedTip(), 'Pausar', reason: 'and back left along the buttons');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('left from the song stays in the bar', (tester) async {
    await pumpTvHome(tester);
    await tabTo(tester, () => focusedTip() == 'Abrir o player');
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(focusedTip(), 'Abrir o player');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('up from the buttons goes to the slider, and up from the slider leaves the bar', (tester) async {
    await pumpTvHome(tester);
    await tabTo(tester, () => focusedTip() == 'Próxima');
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(sliderFocused(), isTrue);
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(inBar(), isFalse);
    await tester.pumpWidget(const SizedBox());
  });
}
