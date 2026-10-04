import 'package:flutter/material.dart';

import '../services.dart';
import '../subsonic/models.dart';

/// Builds a song's tile knowing whether it is the current song (the one the device the app
/// controls plays, or has paused) and whether it plays. Lists mark the current song as Spotify
/// does: in the theme's primary color (a selected ListTile), with [icon] while it plays.
class CurrentSong extends StatelessWidget {
  const CurrentSong(this.song, {required this.builder, super.key});

  static const icon = Icons.graphic_eq;

  final Song song;
  final Widget Function(BuildContext context, bool current, bool playing) builder;

  @override
  Widget build(BuildContext context) {
    final connect = ServicesScope.of(context).connect;
    return ListenableBuilder(
      listenable: connect,
      builder: (context, _) {
        final now = connect.nowPlaying;
        final current = now != null && now.songId == song.id;
        return builder(context, current, current && now.playing);
      },
    );
  }
}
