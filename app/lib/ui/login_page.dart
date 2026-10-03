import 'package:flutter/material.dart';

import '../session.dart';
import '../subsonic/api.dart';

/// Server, user and password: the media server's own account, nothing else to create.
class LoginPage extends StatefulWidget {
  const LoginPage({required this.onSignedIn, super.key});

  final void Function(Session session) onSignedIn;

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
    final credentials = SubsonicCredentials.fromPassword(_username.text.trim(), _password.text);
    final api = SubsonicApi(server, credentials);
    try {
      await api.ping();
      final hub = _hub.text.trim();
      final session = Session(
        server: server,
        credentials: credentials,
        deviceId: await Session.deviceIdOfThisInstallation(),
        deviceName: Session.defaultDeviceName(),
        hub: hub.isEmpty ? null : normalizeServer(hub),
      );
      try {
        await session.save();
      } on Exception catch (e) {
        setState(() => _error = 'Entrou, mas não consegui guardar o login no chaveiro do sistema: $e');
        return;
      }
      widget.onSignedIn(session);
    } on SubsonicError catch (e) {
      setState(() => _error = e.isAuth ? 'Usuário ou senha errados.' : 'O servidor recusou: $e');
    } on Exception catch (e) {
      setState(() => _error = 'Não consegui falar com ${server.host}: $e');
    } finally {
      api.close();
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
                    validator: _required,
                  ),
                  TextFormField(
                    controller: _username,
                    decoration: const InputDecoration(labelText: 'Usuário'),
                    validator: _required,
                  ),
                  TextFormField(
                    controller: _password,
                    decoration: const InputDecoration(labelText: 'Senha'),
                    obscureText: true,
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
                    child: _busy
                        ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Entrar'),
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
