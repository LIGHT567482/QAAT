import 'package:flutter/material.dart';

import '../net/auth_client.dart';

/// Mandatory password change for an account still on its seeded default password
/// (`force_password_change` from the login). Appears before any role UI — closing
/// the shared-default-password gap. Calls back once the change succeeds so the
/// app can drop the gate and carry on to the user's home screen.
class ChangePasswordScreen extends StatefulWidget {
  const ChangePasswordScreen({
    super.key,
    required this.auth,
    required this.onChanged,
    this.token = '',
  });

  final AuthClient auth;

  /// Fired once the server confirms the password change; the host then drops the
  /// gate and carries on to the role UI.
  final VoidCallback onChanged;

  /// The current bearer token (still valid until the password changes).
  final String token;

  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen> {
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  String? _error;
  bool _mismatch = false;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  bool get _canSubmit =>
      !_busy &&
      _current.text.isNotEmpty &&
      _next.text.length >= 8 &&
      _confirm.text.isNotEmpty;

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
      _mismatch = false;
    });
    if (_next.text != _confirm.text) {
      setState(() {
        _busy = false;
        _mismatch = true;
      });
      return;
    }
    final err = await widget.auth.changePassword(
        widget.token, _current.text, _next.text);
    if (!mounted) return;
    if (err != null) {
      setState(() {
        _busy = false;
        _error = err;
      });
      return;
    }
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Change password')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            crossAxisAlignment: .stretch,
            children: [
              Text(
                'This account still uses the default password you were given. '
                'Choose your own before continuing.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              if (_mismatch || _error != null) ...[
                Text(
                  _mismatch
                      ? 'The two new passwords do not match.'
                      : _error!,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
                const SizedBox(height: 8),
              ],
              TextField(
                controller: _current,
                enabled: !_busy,
                obscureText: true,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                    labelText: 'Current password',
                    border: OutlineInputBorder()),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _next,
                enabled: !_busy,
                obscureText: true,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                    labelText: 'New password (at least 8 characters)',
                    border: OutlineInputBorder()),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _confirm,
                enabled: !_busy,
                obscureText: true,
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _canSubmit ? _submit() : null,
                decoration: const InputDecoration(
                    labelText: 'Confirm new password',
                    border: OutlineInputBorder()),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _canSubmit ? _submit : null,
                child: Text(_busy ? 'Saving…' : 'Save'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}