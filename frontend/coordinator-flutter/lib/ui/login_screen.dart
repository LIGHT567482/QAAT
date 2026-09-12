import 'package:flutter/material.dart';

import '../net/auth_client.dart';
import '../net/branding.dart';
import '../net/net.dart';
import '../net/session_store.dart';
import 'brand_widgets.dart';

/// Unified KIU QAAT sign-in for every role (coordinator / student / lecturer).
/// Identifier = email, registration number, or staff ID; the app routes by the
/// returned role. A faithful mirror of the native `LoginScreen.kt`: the bundled
/// logo, institution watermark, show/hide password, the clock-fix hint and the
/// LIGHT TECHNOLOGIES footer.
///
/// Two-phase when the account requires TOTP: the first submit answers
/// `MFA_REQUIRED` and reveals the authenticator-code field; the second submit
/// sends `totp_code`.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, this.auth = const AuthClient()});

  final AuthClient auth;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _identifier = TextEditingController();
  final _password = TextEditingController();
  final _totp = TextEditingController();
  bool _needsMfa = false;
  bool _passwordVisible = false;
  bool _busy = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    // Wake the free-tier backend the moment this screen shows, so its cold start
    // overlaps with the person typing, instead of stalling the sign-in.
    Net.warmUp();
  }

  @override
  void dispose() {
    _identifier.dispose();
    _password.dispose();
    _totp.dispose();
    super.dispose();
  }

  bool get _canSubmit =>
      !_busy && _identifier.text.trim().isNotEmpty && _password.text.isNotEmpty;

  Future<void> _submit() async {
    final identifier = _identifier.text.trim();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await widget.auth.appLogin(
        identifier,
        _password.text,
        totp: _needsMfa ? _totp.text : null,
      );
      if (!mounted) return;
      if (result == null) {
        // MFA_REQUIRED — keep the typed credentials, just ask for the code.
        setState(() => _needsMfa = true);
      } else {
        // Adopt the institution's identity now that we carry a token; failures keep
        // the bundled default. Best-effort, fire-and-forget.
        BrandingState.refresh(result.token);
        // Persist the session so a later launch boots straight into the hub without
        // re-typing credentials (offline-tolerant sign-in).
        await SessionStore.save(result);
        if (!mounted) return;
        Navigator.of(context).pushNamedAndRemoveUntil(
          '/home',
          (_) => false,
          arguments: result,
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final branding = BrandingState.current.value;
    final friendly = Net.friendly;
    final errorText = _error == null ? null : friendly(_error!);
    return Scaffold(
      body: Stack(
        children: [
          // Faint institution-logo watermark behind everything.
          const Center(
            child: Opacity(
              opacity: 0.05,
              child: Image(
                image: AssetImage('assets/branding/qaat_logo.png'),
                width: 340,
                height: 340,
                fit: BoxFit.contain,
              ),
            ),
          ),
          Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Center(
                      child: BrandLogo(branding: null, size: 112),
                    ),
                    const SizedBox(height: 14),
                    Text('KIU QAAT',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineMedium),
                    const SizedBox(height: 2),
                    Text(
                      'Sign in — staff email, registration number, or staff ID',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 24),
                    TextField(
                      controller: _identifier,
                      enabled: !_busy,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        labelText: 'Email / Reg. no / Staff ID',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _password,
                      enabled: !_busy,
                      obscureText: !_passwordVisible,
                      onChanged: (_) => setState(() {}),
                      onSubmitted: (_) => _canSubmit ? _submit() : null,
                      decoration: InputDecoration(
                        labelText: 'Password',
                        border: const OutlineInputBorder(),
                        suffixIcon: TextButton(
                          onPressed: () => setState(
                              () => _passwordVisible = !_passwordVisible),
                          child:
                              Text(_passwordVisible ? 'Hide' : 'Show'),
                        ),
                      ),
                    ),
                    if (_needsMfa) ...[
                      const SizedBox(height: 8),
                      TextField(
                        controller: _totp,
                        enabled: !_busy,
                        keyboardType: TextInputType.number,
                        onChanged: (_) => setState(() {}),
                        onSubmitted: (_) => _canSubmit ? _submit() : null,
                        decoration: const InputDecoration(
                          labelText: 'Authenticator code',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ],
                    if (errorText != null) ...[
                      const SizedBox(height: 8),
                      Text(errorText,
                          style: TextStyle(color: theme.colorScheme.error)),
                      _ClockFixHint(errorText: errorText),
                    ],
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: _canSubmit ? _submit : null,
                      child: Text(_busy ? 'Signing in…' : 'Sign in'),
                    ),
                    if (_busy) ...[
                      const SizedBox(height: 10),
                      const LinearProgressIndicator(),
                      const SizedBox(height: 6),
                      Text(
                        'Contacting the server… the first sign-in can take up to a minute '
                        'while it wakes up. Please keep waiting.',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 16,
            child: Text(
              branding?.motto.isNotEmpty == true
                  ? '${branding?.name} · ${branding?.motto}'
                  : 'Powered by LIGHT TECHNOLOGIES',
              textAlign: TextAlign.center,
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

/// A "Secure connection failed" almost always means the phone's clock is wrong
/// (phones with no SIM never network-sync their time). Surface the exact fix.
class _ClockFixHint extends StatelessWidget {
  const _ClockFixHint({required this.errorText});

  final String errorText;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = errorText.toLowerCase();
    if (!hint.contains('date') && !hint.contains('time') &&
        !hint.contains('secure connection')) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: theme.colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          'Fix: Settings → System → Date & time → turn ON "Set time '
          'automatically" (or set today’s correct date), then tap Sign in again. '
          'A wrong clock blocks the secure connection.',
          style: theme.textTheme.bodySmall!.copyWith(
            color: theme.colorScheme.onErrorContainer,
          ),
        ),
      ),
    );
  }
}