import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segue/ui/spinner.dart';

void main() {
  Future<void> pumpSpinner(WidgetTester tester) => tester.pumpWidget(
    const MaterialApp(
      home: Center(child: Spinner(size: 20, strokeWidth: 2.5, color: Colors.teal)),
    ),
  );

  testWidgets('the arc is a whole circle shown only along it, with round ends: no arcs, which Impeller leaves '
      'jagged', (tester) async {
    await pumpSpinner(tester);
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      find.byType(Spinner),
      paints
        ..circle(x: 10, y: 10, radius: 8.75, style: PaintingStyle.stroke, strokeWidth: 2.5)
        ..circle(radius: 1.25, color: Colors.teal, style: PaintingStyle.fill)
        ..circle(radius: 1.25, color: Colors.teal, style: PaintingStyle.fill),
    );
    expect(find.byType(Spinner), isNot(paints..arc()));
    expect(find.byType(Spinner), isNot(paints..path()));
  });

  testWidgets('it starts as a dot at the top, and moves', (tester) async {
    await pumpSpinner(tester);
    final dotAtTheTop = paints
      ..circle(x: 10, y: 10, radius: 8.75)
      ..circle(x: 10, y: 1.25)
      ..circle(x: 10, y: 1.25);
    expect(find.byType(Spinner), dotAtTheTop);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(Spinner), isNot(dotAtTheTop));
  });

  test('the app spins with Spinner: CircularProgressIndicator is jagged on Linux', () {
    final drawn = [
      for (final file in Directory('lib').listSync(recursive: true).whereType<File>())
        if (file.path.endsWith('.dart') && file.readAsStringSync().contains('CircularProgressIndicator(')) file.path,
    ];
    expect(drawn, isEmpty);
  });
}
