import 'package:flutter/material.dart';

import '../services.dart';

/// A cover from the media server, or a placeholder.
class Cover extends StatelessWidget {
  const Cover(this.id, {this.size = 300, super.key});

  final String? id;

  /// Pixels asked of the server.
  final int size;

  @override
  Widget build(BuildContext context) {
    final placeholder = ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: const Center(child: Icon(Icons.album_outlined)),
    );
    final id = this.id;
    if (id == null) return placeholder;
    return Image.network(
      ServicesScope.of(context).api.coverArtUrl(id, size: size).toString(),
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => placeholder,
    );
  }
}
