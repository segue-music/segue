import 'package:flutter/material.dart';

import 'player/audio_interruptions.dart';
import 'player/media_controls.dart';
import 'services.dart';
import 'session.dart';
import 'ui/home_page.dart';
import 'ui/login_page.dart';
import 'ui/shortcuts.dart';
import 'ui/theme.dart';

class SegueApp extends StatefulWidget {
  const SegueApp({required this.session, this.mediaControls, this.interruptions, this.television = false, super.key});

  /// The saved session, if any: then the app opens straight on the library.
  final Session? session;

  /// The system's media controls, where the platform has them.
  final MediaControls? mediaControls;

  /// Calls and the like pausing this device's playback, where the platform has them.
  final AudioInterruptions? interruptions;

  /// Whether it runs on a TV, driven by a remote's D-pad.
  final bool television;

  @override
  State<SegueApp> createState() => _SegueAppState();
}

class _SegueAppState extends State<SegueApp> {
  Services? _services;
  bool _starting = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    final session = widget.session;
    if (session != null) _start(session);
  }

  Future<void> _start(Session session) async {
    setState(() {
      _starting = true;
      _error = null;
    });
    try {
      final services = await Services.start(session);
      if (!mounted) {
        await services.dispose();
        return;
      }
      setState(() => _services = services);
      widget.mediaControls?.attach(services.connect, services.api);
      widget.interruptions?.attach(services.player);
    } on Exception catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _signOut() async {
    final services = _services;
    setState(() {
      _services = null;
      _error = null;
    });
    widget.mediaControls?.attach(null, null);
    widget.interruptions?.attach(null);
    await services?.api.signOut();
    await services?.dispose();
    await Session.clear();
  }

  @override
  Widget build(BuildContext context) {
    final services = _services;
    return MaterialApp(
      title: 'Segue',
      debugShowCheckedModeBanner: false,
      theme: segueTheme(Brightness.light),
      darkTheme: segueTheme(Brightness.dark),
      // Above the navigator, so that every page and sheet sees the services and the shortcuts.
      builder: (context, child) {
        final page = DirectionalNavigation(
          enabled: widget.television,
          child: TextFieldArrowShortcuts(child: child!),
        );
        if (services == null) return page;
        return ServicesScope(
          services: services,
          // The media keys, too, where no system media session takes them.
          child: PlaybackShortcuts(mediaKeys: widget.mediaControls == null, child: page),
        );
      },
      home: services != null
          ? HomePage(onSignOut: _signOut)
          : _starting
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : _error != null
          ? Scaffold(
              body: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Erro ao abrir: $_error'),
                    TextButton(onPressed: _signOut, child: const Text('Sair')),
                  ],
                ),
              ),
            )
          : LoginPage(onSignedIn: _start),
    );
  }
}
