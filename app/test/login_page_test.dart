import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segue/app.dart';
import 'package:segue/session.dart';
import 'package:segue/ui/login_page.dart';

/// Whether the text field labelled [label] has the focus.
bool focused(WidgetTester tester, String label) => tester
    .widget<EditableText>(
      find.descendant(of: find.widgetWithText(TextFormField, label), matching: find.byType(EditableText)),
    )
    .focusNode
    .hasFocus;

void main() {
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

  test('a server typed without a scheme is https', () {
    expect(normalizeServer(' music.test:4533 ').toString(), 'https://music.test:4533');
    expect(normalizeServer('http://127.0.0.1:8480').toString(), 'http://127.0.0.1:8480');
  });
}
