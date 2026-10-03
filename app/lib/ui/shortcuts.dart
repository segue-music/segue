import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services.dart';
import 'errors.dart';

/// Keyboard shortcuts for playback, on every page: space plays or pauses what the now-playing bar
/// shows, as in Spotify. Not while typing: with a text field focused, the key goes on to it.
class PlaybackShortcuts extends StatelessWidget {
  const PlaybackShortcuts({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) => Shortcuts(
    shortcuts: const {SingleActivator(LogicalKeyboardKey.space): PlayPauseIntent()},
    child: Actions(actions: {PlayPauseIntent: _PlayPauseAction(() => _toggle(context))}, child: child),
  );

  static Future<void> _toggle(BuildContext context) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final result = await ServicesScope.of(context).connect.toggle();
    if (!result.ok) messenger?.showSnackBar(SnackBar(content: Text(describeError(result.error))));
  }
}

class PlayPauseIntent extends Intent {
  const PlayPauseIntent();
}

class _PlayPauseAction extends Action<PlayPauseIntent> {
  _PlayPauseAction(this._playPause);

  final VoidCallback _playPause;

  /// Disabled while typing, so that the key isn't taken from the text field.
  @override
  bool isEnabled(PlayPauseIntent intent) {
    final focused = FocusManager.instance.primaryFocus?.context;
    return focused == null ||
        (focused.widget is! EditableText && focused.findAncestorWidgetOfExactType<EditableText>() == null);
  }

  @override
  Object? invoke(PlayPauseIntent intent) {
    _playPause();
    return null;
  }
}
