import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segue/session.dart';
import 'package:segue/ui/login_page.dart';

void main() {
  testWidgets('asks for server, user and password before trying', (tester) async {
    var signedIn = false;
    await tester.pumpWidget(MaterialApp(home: LoginPage(onSignedIn: (_) => signedIn = true)));
    await tester.tap(find.text('Entrar'));
    await tester.pump();
    expect(find.text('Obrigatório'), findsNWidgets(3));
    expect(signedIn, isFalse);
  });

  test('a server typed without a scheme is https', () {
    expect(normalizeServer(' music.test:4533 ').toString(), 'https://music.test:4533');
    expect(normalizeServer('http://127.0.0.1:8480').toString(), 'http://127.0.0.1:8480');
  });
}
