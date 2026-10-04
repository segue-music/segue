import 'package:flutter/material.dart';

/// The app's theme, light or dark. Whatever has the focus stands out: a TV is driven with a remote
/// from across the room, and Material's own focus highlights are faint. Buttons get a ring; lists,
/// the side rail and the tiles a strong tint (and, where an image would hide it, a FocusRing).
ThemeData segueTheme(Brightness brightness) {
  final colors = ColorScheme.fromSeed(seedColor: Colors.teal, brightness: brightness);
  final ring = WidgetStateProperty.resolveWith(
    (states) => states.contains(WidgetState.focused) ? BorderSide(color: colors.onSurface, width: 3) : null,
  );
  final focusRing = ButtonStyle(side: ring);
  return ThemeData(
    colorScheme: colors,
    focusColor: colors.primary.withValues(alpha: 0.35),
    iconButtonTheme: IconButtonThemeData(style: focusRing),
    filledButtonTheme: FilledButtonThemeData(style: focusRing),
    textButtonTheme: TextButtonThemeData(style: focusRing),
    searchBarTheme: SearchBarThemeData(side: ring),
  );
}
