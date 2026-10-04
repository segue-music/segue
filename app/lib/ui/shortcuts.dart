import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services.dart';
import 'player_controls.dart';

/// Keyboard shortcuts for playback, on every page: space plays or pauses what the now-playing bar
/// shows, as in Spotify. Not while typing: with a text field focused, the key goes on to it.
class PlaybackShortcuts extends StatelessWidget {
  const PlaybackShortcuts({required this.child, this.mediaKeys = false, super.key});

  final Widget child;

  /// Whether the media keys (play/pause, next, previous: a TV remote's, a keyboard's) are taken here
  /// too. Where a system media session takes them (MPRIS on Linux), they never come as keys; where
  /// there is none (Android, for now), they do.
  final bool mediaKeys;

  @override
  Widget build(BuildContext context) {
    final connect = ServicesScope.of(context).connect;
    return Shortcuts(
      shortcuts: {
        const SingleActivator(LogicalKeyboardKey.space): const PlayPauseIntent(),
        if (mediaKeys) ...{
          const SingleActivator(LogicalKeyboardKey.mediaPlayPause): const PlayPauseIntent(whileTyping: true),
          const SingleActivator(LogicalKeyboardKey.mediaTrackNext): const _NextIntent(),
          const SingleActivator(LogicalKeyboardKey.mediaTrackPrevious): const _PreviousIntent(),
        },
      },
      child: Actions(
        actions: {
          PlayPauseIntent: _PlayPauseAction(() => runCommand(context, connect.toggle)),
          _NextIntent: CallbackAction<_NextIntent>(onInvoke: (_) => runCommand(context, connect.next)),
          _PreviousIntent: CallbackAction<_PreviousIntent>(onInvoke: (_) => runCommand(context, connect.previous)),
        },
        child: child,
      ),
    );
  }
}

class PlayPauseIntent extends Intent {
  const PlayPauseIntent({this.whileTyping = false});

  /// A media key, which a text field doesn't take, so it works while typing too.
  final bool whileTyping;
}

class _NextIntent extends Intent {
  const _NextIntent();
}

class _PreviousIntent extends Intent {
  const _PreviousIntent();
}

class _PlayPauseAction extends Action<PlayPauseIntent> {
  _PlayPauseAction(this._playPause);

  final VoidCallback _playPause;

  /// Disabled while typing, so that the key isn't taken from the text field.
  @override
  bool isEnabled(PlayPauseIntent intent) {
    if (intent.whileTyping) return true;
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

/// The arrows up and down (a TV remote's D-pad) leave a text field for the one above or below. By
/// default they stay in it, moving the caret, and a remote has no other way out. Left and right
/// still move the caret.
class TextFieldArrowShortcuts extends StatelessWidget {
  const TextFieldArrowShortcuts({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) => Shortcuts(
    shortcuts: const {
      SingleActivator(LogicalKeyboardKey.arrowUp): DirectionalFocusIntent(
        TraversalDirection.up,
        ignoreTextFields: false,
      ),
      SingleActivator(LogicalKeyboardKey.arrowDown): DirectionalFocusIntent(
        TraversalDirection.down,
        ignoreTextFields: false,
      ),
    },
    child: child,
  );
}
