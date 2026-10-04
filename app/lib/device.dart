import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

const _channel = MethodChannel('segue/device');

/// Whether the app runs on a TV (Android TV, Google TV), asked of Android, which knows by its UI
/// mode (MainActivity.kt). Elsewhere there is no such channel, and it is no TV.
Future<bool> isTelevision() async {
  try {
    return await _channel.invokeMethod<bool>('isTelevision') ?? false;
  } on MissingPluginException {
    return false;
  }
}

/// On a TV, the focus always shows. Flutter starts Android as if it were touched, and shows the
/// focus only after a key from a hardware keyboard; but a TV has no touch screen, and a remote's
/// keys can come as a virtual keyboard's (adb's do), which Flutter doesn't count.
Future<void> adaptToTelevision() async {
  if (await isTelevision()) FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTraditional;
}

/// The device's name, as its owner knows it: on Android, the one in the system settings, or else its
/// maker and model (MainActivity.kt); elsewhere, the computer's.
Future<String> systemDeviceName() async {
  try {
    final name = await _channel.invokeMethod<String>('deviceName');
    if (name != null && name.trim().isNotEmpty) return name.trim();
  } on MissingPluginException {
    // no such channel: not Android
  }
  return Platform.isIOS ? 'iPhone' : Platform.localHostname;
}
