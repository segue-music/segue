import 'package:flutter/material.dart';

import '../services.dart';
import 'current_song.dart';

/// A cover from the media server, or a placeholder.
class Cover extends StatelessWidget {
  const Cover(this.id, {this.size = 300, this.icon = Icons.album_outlined, super.key});

  final String? id;

  /// Pixels asked of the server.
  final int size;

  /// What the placeholder shows.
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final placeholder = ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Center(child: Icon(icon)),
    );
    final id = this.id;

    if (id == null) {
      return placeholder;
    }

    return Image.network(
      ServicesScope.of(context).api.coverArtUrl(id, size: size).toString(),
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => placeholder,
    );
  }
}

/// A small cover, for a list.
class Thumbnail extends StatelessWidget {
  const Thumbnail(this.coverArt, {this.round = false, this.playing = false, super.key});

  final String? coverArt;

  /// An artist's: round, with a person for a placeholder.
  final bool round;

  /// A song's that plays: the equalizer goes over it, on a veil.
  final bool playing;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 48,
    child: round
        ? ClipOval(child: Cover(coverArt, size: 96, icon: Icons.person_outline))
        : ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Cover(coverArt, size: 96),
                // The primary color's light tone in either theme, which stands out on the dark veil.
                if (playing)
                  ColoredBox(
                    color: Colors.black54,
                    child: Icon(CurrentSong.icon, color: Theme.of(context).colorScheme.primaryFixedDim),
                  ),
              ],
            ),
          ),
  );
}
