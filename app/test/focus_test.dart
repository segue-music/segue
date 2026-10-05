import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segue/server/models.dart';
import 'package:segue/ui/albums_view.dart';
import 'package:segue/ui/theme.dart';

/// How many things on screen have a ring drawn around them.
int rings(WidgetTester tester) => tester
    .widgetList<DecoratedBox>(find.byType(DecoratedBox))
    .where((box) => box.decoration is BoxDecoration && (box.decoration as BoxDecoration).border != null)
    .length;

bool ringed(WidgetTester tester) => rings(tester) > 0;

/// Where the ring is.
Rect ringAt(WidgetTester tester) => tester.getRect(
  find.byWidgetPredicate(
    (widget) =>
        widget is DecoratedBox &&
        widget.decoration is BoxDecoration &&
        (widget.decoration as BoxDecoration).border != null,
  ),
);

void main() {
  test('the theme makes what has the focus stand out: a thick ring on buttons, a strong tint elsewhere', () {
    for (final brightness in Brightness.values) {
      final theme = segueTheme(brightness);
      expect(theme.focusColor.a, greaterThanOrEqualTo(0.3), reason: '$brightness focus tint');
      final styles = {
        'icon': theme.iconButtonTheme.style,
        'filled': theme.filledButtonTheme.style,
        'text': theme.textButtonTheme.style,
      };

      for (final MapEntry(key: name, value: style) in styles.entries) {
        final focused = style?.side?.resolve({WidgetState.focused});
        expect(focused?.width, greaterThanOrEqualTo(2), reason: '$brightness $name button, focused');
        expect(focused?.color, theme.colorScheme.onSurface, reason: '$brightness $name button, focused');
        expect(style?.side?.resolve({}), isNull, reason: '$brightness $name button, not focused');
      }

      final searchBar = theme.searchBarTheme.side;
      expect(searchBar?.resolve({WidgetState.focused})?.width, greaterThanOrEqualTo(2), reason: '$brightness search');
      expect(searchBar?.resolve({}), isNull, reason: '$brightness search bar, not focused');
    }
  });

  testWidgets('an album gets a ring while it has the focus from the keyboard or a remote, not from a touch', (
    tester,
  ) async {
    addTearDown(() => FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic);
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTraditional;
    await tester.pumpWidget(
      MaterialApp(
        theme: segueTheme(Brightness.light),
        home: const Scaffold(
          body: AlbumGrid([Album(id: 'a1', name: 'Toys in the Attic', artist: 'Aerosmith')]),
        ),
      ),
    );
    expect(ringed(tester), isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(ringed(tester), isTrue);

    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTouch;
    await tester.pump();
    expect(ringed(tester), isFalse);
  });

  testWidgets('the ring goes with the focus: one thing at a time', (tester) async {
    addTearDown(() => FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic);
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTraditional;
    await tester.pumpWidget(
      MaterialApp(
        theme: segueTheme(Brightness.light),
        home: const Scaffold(
          body: AlbumGrid([Album(id: 'a1', name: 'One'), Album(id: 'a2', name: 'Two')]),
        ),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(rings(tester), 1);
    final first = ringAt(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(rings(tester), 1);
    expect(ringAt(tester), isNot(first), reason: 'the ring moved to the other album');
    // And the focus went with it, at the first press: the ring didn't take it away from the album.
    expect(FocusManager.instance.primaryFocus?.rect, ringAt(tester));
  });
}
