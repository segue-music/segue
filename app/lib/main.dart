import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'app.dart';
import 'player/media_controls.dart';
import 'session.dart';
import 'device.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  final television = await adaptToTelevision();
  final controls = await MediaControls.start();
  runApp(SegueApp(session: await Session.load(), mediaControls: controls, television: television));
}
