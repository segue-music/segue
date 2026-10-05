import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:segue/app.dart';
import 'package:segue/jellyfin/api.dart';
import 'package:segue/session.dart';
import 'package:segue/ui/login_page.dart';
import 'package:segue/ui/spinner.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

/// Whether the text field labelled [label] has the focus.
bool focused(WidgetTester tester, String label) => tester
    .widget<EditableText>(
      find.descendant(of: find.widgetWithText(TextFormField, label), matching: find.byType(EditableText)),
    )
    .focusNode
    .hasFocus;

Future<void> fillIn(WidgetTester tester, {required String server}) async {
  await tester.enterText(find.widgetWithText(TextFormField, 'Servidor'), server);
  await tester.enterText(find.widgetWithText(TextFormField, 'Usuário'), 'alice');
  await tester.enterText(find.widgetWithText(TextFormField, 'Senha'), 'sesame');
  await tester.tap(find.text('Entrar'));
  await tester.pumpAndSettle();
}

void main() {
  SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
  FlutterSecureStorage.setMockInitialValues({});
  // The system's name for the device comes from a platform channel, which doesn't answer here.
  setUpAll(() => SharedPreferencesAsync().setString('deviceName', 'laptop'));

  testWidgets('asks for server, user and password before trying', (tester) async {
    var signedIn = false;
    await tester.pumpWidget(MaterialApp(home: LoginPage(onSignedIn: (_) => signedIn = true)));
    await tester.tap(find.text('Entrar'));
    await tester.pump();
    expect(find.text('Obrigatório'), findsNWidgets(3));
    expect(signedIn, isFalse);
  });

  testWidgets('the keyboard offers "next" from field to field, and from the password, signing in', (tester) async {
    await tester.pumpWidget(MaterialApp(home: LoginPage(onSignedIn: (_) {})));
    for (final (label, action) in [
      ('Servidor', 'TextInputAction.next'),
      ('Usuário', 'TextInputAction.next'),
      ('Senha', 'TextInputAction.done'),
    ]) {
      await tester.tap(find.widgetWithText(TextFormField, label));
      await tester.pump();
      expect(tester.testTextInput.setClientArgs?['inputAction'], action, reason: label);
    }
    await tester.tap(find.widgetWithText(TextFormField, 'Servidor'));
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pump();
    expect(focused(tester, 'Usuário'), isTrue);
  });

  testWidgets('in the app, the arrows down and up (a TV remote\'s) go from field to field', (tester) async {
    await tester.pumpWidget(const SegueApp(session: null));
    await tester.tap(find.widgetWithText(TextFormField, 'Servidor'));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(focused(tester, 'Usuário'), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(focused(tester, 'Senha'), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(focused(tester, 'Usuário'), isTrue);
  });

  testWidgets('while it signs in, the button spins and can\'t be pressed again', (tester) async {
    final answer = Completer<http.Response>();
    final client = MockClient((_) => answer.future);
    await tester.pumpWidget(
      MaterialApp(
        home: LoginPage(onSignedIn: (_) {}, client: client),
      ),
    );
    await tester.enterText(find.widgetWithText(TextFormField, 'Servidor'), 'music.test');
    await tester.enterText(find.widgetWithText(TextFormField, 'Usuário'), 'alice');
    await tester.enterText(find.widgetWithText(TextFormField, 'Senha'), 'sesame');
    await tester.tap(find.text('Entrar'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.descendant(of: find.byType(FilledButton), matching: find.byType(Spinner)), findsOneWidget);
    expect(find.text('Entrar'), findsNothing);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);
    answer.complete(http.Response('<!doctype html>', 200));
    await tester.pumpAndSettle();
    expect(find.byType(Spinner), findsNothing);
    expect(find.text('Entrar'), findsOneWidget);
  });

  testWidgets('a Jellyfin server is found by its address alone, and signed in to', (tester) async {
    Session? signedIn;
    final client = MockClient((request) async {
      final body = switch (request.url.path) {
        '/System/Info/Public' => {'Id': 'abc', 'Version': '10.10.7'},
        '/Users/AuthenticateByName' => {
          'User': {'Name': 'alice', 'Id': 'u1'},
          'AccessToken': 't1',
        },
        _ => null,
      };
      return body == null ? http.Response('', 404) : http.Response(jsonEncode(body), 200);
    });
    await tester.pumpWidget(
      MaterialApp(
        home: LoginPage(onSignedIn: (session) => signedIn = session, client: client),
      ),
    );
    await fillIn(tester, server: 'music.test');
    expect(signedIn?.server, Uri.parse('https://music.test'));
    expect(signedIn?.credentials, isA<JellyfinCredentials>().having((c) => c.token, 'token', 't1'));
  });

  testWidgets('an address with no media server says so', (tester) async {
    final client = MockClient((_) async => http.Response('<!doctype html>', 200));
    await tester.pumpWidget(
      MaterialApp(
        home: LoginPage(onSignedIn: (_) {}, client: client),
      ),
    );
    await fillIn(tester, server: 'example.test');
    expect(find.text('Não achei um servidor Subsonic nem Jellyfin em example.test.'), findsOneWidget);
  });

  test('a server typed without a scheme is https', () {
    expect(normalizeServer(' music.test:4533 ').toString(), 'https://music.test:4533');
    expect(normalizeServer('http://127.0.0.1:8480').toString(), 'http://127.0.0.1:8480');
  });
}
