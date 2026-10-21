import 'package:flutter/material.dart';

import '../../../core/api/api_client.dart';
import '../../../core/auth/auth_repository.dart';

/// Sign-in for students and lecturers (spec doc 05 §2 — identifier order:
/// email, registration number, or staff number; fixed 401 on failure).
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.auth, required this.onSignedIn});

  final AuthRepository auth;
  final void Function(User user) onSignedIn;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _login = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;
  bool _registerMode = false;

  // registration fields
  final _fullName = TextEditingController();
  final _regNo = TextEditingController();

  @override
  void dispose() {
    _login.dispose();
    _password.dispose();
    _fullName.dispose();
    _regNo.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final User user;
      if (_registerMode) {
        user = await widget.auth.api.register(
          email: _login.text,
          password: _password.text,
          fullName: _fullName.text,
          registrationNumber: _regNo.text,
        );
        await widget.auth.saveSession(widget.auth.api.token ?? '', user);
      } else {
        user = await widget.auth.api.login(_login.text, _password.text);
        await widget.auth.saveSession(widget.auth.api.token ?? '', user);
      }
      if (!mounted) return;
      widget.onSignedIn(user);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('QAAT',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: 4),
                Text(
                  _registerMode ? 'Create your student account' : 'Student & lecturer sign-in',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: _login,
                  decoration: const InputDecoration(
                    labelText: 'Email or registration number',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.emailAddress,
                ),
                if (_registerMode) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: _fullName,
                    decoration: const InputDecoration(
                      labelText: 'Full name',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _regNo,
                    decoration: const InputDecoration(
                      labelText: 'Registration number (e.g. KIU3454S)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                TextField(
                  controller: _password,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Password',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _submit(),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ],
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: _busy ? null : _submit,
                  child: Text(_busy
                      ? 'Please wait…'
                      : (_registerMode ? 'Create account' : 'Sign in')),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => setState(() {
                            _registerMode = !_registerMode;
                            _error = null;
                          }),
                  child: Text(_registerMode
                      ? 'Have an account? Sign in'
                      : 'New student? Create an account'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
