import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../server/server.dart';
import '../server/sign_in.dart';
import '../session.dart';
import 'spinner.dart';

/// Server, user and password: the media server's own account, nothing else to create. Whether the
/// server speaks Subsonic or Jellyfin, the app finds out.
class LoginPage extends StatefulWidget {
  const LoginPage({required this.onSignedIn, @visibleForTesting this.client, super.key});

  final void Function(Session session) onSignedIn;

  /// What talks to the media server, for tests.
  final http.Client? client;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _form = GlobalKey<FormState>();
  final _server = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _hub = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final controller in [_server, _username, _password, _hub]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final server = normalizeServer(_server.text);
    MediaServer? api;
    try {
      final deviceId = await Session.thisDeviceId();
      final deviceName = await Session.thisDeviceName();
      api = await signIn(
        server,
        _username.text.trim(),
        _password.text,
        deviceId: deviceId,
        deviceName: deviceName,
        client: widget.client,
      );
      final hub = _hub.text.trim();
      final session = Session(
        server: server,
        credentials: api.credentials,
        deviceId: deviceId,
        deviceName: deviceName,
        hub: hub.isEmpty ? null : normalizeServer(hub),
      );
      try {
        await session.save();
      } on Exception catch (e) {
        setState(() => _error = 'Entrou, mas não consegui guardar o login no chaveiro do sistema: $e');
        return;
      }
      widget.onSignedIn(session);
    } on NotAMediaServer {
      setState(() => _error = 'Não achei um servidor Subsonic nem Jellyfin em ${server.host}.');
    } on ServerError catch (e) {
      setState(() => _error = e.isAuth ? 'Usuário ou senha errados.' : 'O servidor recusou: $e');
    } on Exception catch (e) {
      setState(() => _error = 'Não consegui falar com ${server.host}: $e');
    } finally {
      api?.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  String? _required(String? value) => (value ?? '').trim().isEmpty ? 'Obrigatório' : null;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Form(
              key: _form,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Segue', style: Theme.of(context).textTheme.headlineLarge, textAlign: TextAlign.center),
                  const SizedBox(height: 32),
                  TextFormField(
                    controller: _server,
                    decoration: const InputDecoration(labelText: 'Servidor', hintText: 'musica.exemplo.com:4533'),
                    keyboardType: TextInputType.url,
                    // The keyboard's button goes on to the next field (a TV's keyboard has no other way).
                    textInputAction: TextInputAction.next,
                    validator: _required,
                  ),
                  TextFormField(
                    controller: _username,
                    decoration: const InputDecoration(labelText: 'Usuário'),
                    textInputAction: TextInputAction.next,
                    validator: _required,
                  ),
                  TextFormField(
                    controller: _password,
                    decoration: const InputDecoration(labelText: 'Senha'),
                    obscureText: true,
                    textInputAction: TextInputAction.done,
                    validator: _required,
                    onFieldSubmitted: (_) => _submit(),
                  ),
                  ExpansionTile(
                    title: const Text('Avançado'),
                    tilePadding: EdgeInsets.zero,
                    children: [
                      TextFormField(
                        controller: _hub,
                        decoration: const InputDecoration(
                          labelText: 'Endereço do hub (opcional)',
                          helperText: 'Em branco, ele é procurado no endereço do servidor.',
                        ),
                        keyboardType: TextInputType.url,
                        textInputAction: TextInputAction.done,
                        onFieldSubmitted: (_) => _submit(),
                      ),
                    ],
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  ],
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _busy ? null : _submit,
                    child: _busy ? const Spinner(size: 20, strokeWidth: 2.5) : const Text('Entrar'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
