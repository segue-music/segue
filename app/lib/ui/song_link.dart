import 'dart:async';

import 'package:flutter/material.dart';

import '../connect/connect.dart';
import '../server/models.dart';
import '../services.dart';
import 'album_page.dart';
import 'artist_page.dart';

/// The title or the album of the song that plays, a link to the album, or its artist, a link to their
/// page (the first, when it has several): underlined under the mouse, and tinted under the focus as
/// everything else is. A song without an id in this device's API (one the hub couldn't translate)
/// links nowhere.
class SongLink extends StatefulWidget {
  /// The song's title, which opens its album.
  const SongLink.title(this.now, {this.style, this.maxLines = 1, this.replace = false, super.key})
    : _part = _Part.title;

  /// The name of the song's album, which opens it.
  const SongLink.album(this.now, {this.style, this.maxLines = 1, this.replace = false, super.key})
    : _part = _Part.album;

  /// The song's artist, who opens their page.
  const SongLink.artist(this.now, {this.style, this.maxLines = 1, this.replace = false, super.key})
    : _part = _Part.artist;

  final NowPlaying now;
  final TextStyle? style;
  final int maxLines;

  /// Whether the page goes in place of the current one (the full-screen player), rather than over it.
  final bool replace;

  final _Part _part;

  @override
  State<SongLink> createState() => _SongLinkState();
}

/// What a [SongLink] shows of the song.
enum _Part {
  title,
  album,
  artist;

  /// The word the app's messages use for what it opens: the album, but for the artist.
  String get word => this == artist ? 'artista' : 'álbum';
}

class _SongLinkState extends State<SongLink> {
  bool _hovered = false;

  /// Opens the album or the artist, or says why it can't. The song comes from the media server: the
  /// hub gives other devices' songs without their album's and artist's ids.
  Future<void> _open(String songId) async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    Widget? page;
    Object? error;

    try {
      final song = await ServicesScope.of(context).api.song(songId);
      page = switch ((widget._part, song)) {
        (_Part.artist, Song(artistId: final id?)) => ArtistPage(Artist(id: id, name: song.artist ?? '')),
        (_Part.title || _Part.album, Song(albumId: final id?)) => AlbumPage(Album(id: id, name: song.album ?? '')),
        _ => null,
      };
    } on Object catch (failure) {
      error = failure;
    }

    // The song stopped showing meanwhile, as when the player closed.
    if (!mounted) {
      return;
    }

    if (page case final opened?) {
      final route = MaterialPageRoute<void>(builder: (_) => opened);
      unawaited(widget.replace ? navigator.pushReplacement(route) : navigator.push(route));
      return;
    }

    final word = widget._part.word;
    messenger.showSnackBar(SnackBar(content: Text('Não consegui abrir o $word${error == null ? '.' : ': $error'}')));
  }

  @override
  Widget build(BuildContext context) {
    final now = widget.now;
    final songId = now.songId;
    final link = InkWell(
      onTap: songId == null ? null : () => _open(songId),
      onHover: (hovered) => setState(() => _hovered = hovered),
      hoverColor: Colors.transparent,
      borderRadius: BorderRadius.circular(4),
      child: Text(
        switch (widget._part) {
          _Part.title => now.title ?? 'Nada tocando',
          _Part.album => now.album ?? '',
          _Part.artist => now.artist ?? '',
        },
        style: _hovered
            ? (widget.style ?? const TextStyle()).copyWith(decoration: TextDecoration.underline)
            : widget.style,
        maxLines: widget.maxLines,
        overflow: TextOverflow.ellipsis,
      ),
    );

    if (songId == null) {
      return link;
    }

    return Tooltip(message: 'Abrir o ${widget._part.word}', child: link);
  }
}
