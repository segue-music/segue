import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'protocol.dart';

/// Finds the hub next to a media server (SPEC.md, "Discovery") and returns its WebSocket URL, or
/// null when there is none. [hub], when given, is the hub's own address, typed by the user.
Future<Uri?> discoverHub(Uri server, {Uri? hub, http.Client? client}) async {
  final candidates = hub != null ? [hub] : [server, if (server.path.length > 1) server.replace(path: '/')];
  final http_ = client ?? http.Client();

  try {
    for (final base in candidates) {
      // The hub answers under /connect/ whether or not a proxy strips it, so this works both for
      // the media server's origin and for the hub's own address.
      final root = base.path.endsWith('/') ? base : base.replace(path: '${base.path}/');

      try {
        final response = await http_.get(root.resolve('connect/v1/info')).timeout(const Duration(seconds: 3));

        if (response.statusCode != 200) {
          continue;
        }

        final info = jsonDecode(response.body);

        if (info is Map &&
            info['protocol'] == 'segue' &&
            (info['versions'] as List?)?.contains(protocolVersion) == true) {
          final ws = root.resolve('connect/v1/ws');
          return ws.replace(scheme: ws.scheme == 'https' ? 'wss' : 'ws');
        }
      } on Exception {
        continue; // not reachable, not JSON, or not a hub
      }
    }

    return null;
  } finally {
    if (client == null) {
      http_.close();
    }
  }
}
