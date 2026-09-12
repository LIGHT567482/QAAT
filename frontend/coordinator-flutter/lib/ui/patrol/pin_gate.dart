import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../net/branding.dart';
import '../../patrol/patrol_client.dart';
import '../brand_widgets.dart';
import 'sign_out_button.dart';

/// The monitor's SECOND page — the one they land on after a successful sign-in,
/// before the round. A faithful port of the native `PatrolPinGate.kt`.
///
/// WHY ONLY THIS ROLE. A monitor tick is an accusation: it records that a named
/// lecturer was or was not teaching, and QA weighs it against the coordinator's own
/// log precisely because it comes from an independent observer. The account password
/// is the weak link — it is what gets shared "just to help cover the rounds this
/// week" — and once shared, anyone can mark any lecturer absent. No other role can
/// do damage of that shape from a borrowed password, so no other role is asked for
/// more.
///
/// FIRST SIGN-IN sets the PIN; every sign-in after asks for it. It is verified
/// SERVER-side, never locally: a secret a stolen handset can check for itself is not
/// a second factor, it is a delay. The round therefore cannot open offline — the
/// trade is deliberate, and the message says so.
class PatrolPinGate extends StatefulWidget {
  const PatrolPinGate({
    super.key,
    required this.token,
    required this.buildRound,
  });

  final String token;

  /// The round UI, shown once the PIN is proven. Not built (even as a widget tree)
  /// until then — exactly like the native gate swapping its subtree.
  final WidgetBuilder buildRound;

  @override
  State<PatrolPinGate> createState() => _PatrolPinGateState();
}

class _PatrolPinGateState extends State<PatrolPinGate> {
  final PatrolClient _client = PatrolClient();
  bool _unlocked = false;
  PinState? _state;
  bool _loadFailed = false;

  Future<void> _refresh() async {
    final s = await _client.pinState(widget.token);
    if (!mounted) return;
    setState(() {
      _loadFailed = s == null;
      _state = s;
    });
  }

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    if (_unlocked) return widget.buildRound(context);
    if (_loadFailed) {
      return PinMessageScreen(
        title: "Can't check your PIN",
        body: 'Monitoring needs a connection to unlock. Find signal and try again — '
            'your saved ticks are safe.',
        child: _retryButton('Try again', onPressed: () {
          setState(() => _loadFailed = false);
          _refresh();
        }),
      );
    }
    final s = _state;
    if (s == null) {
      return PinScaffold(
        title: '…',
        blurb: 'Checking your monitor account…',
        child: const Center(
          child: Padding(
            padding: EdgeInsets.only(top: 12),
            child: CircularProgressIndicator(),
          ),
        ),
      );
    }
    if (!s.isSet) {
      return SetPinScreen(token: widget.token, onDone: () => setState(() => _unlocked = true));
    }
    return EnterPinScreen(
      token: widget.token,
      initiallyLocked: s.locked,
      attemptsLeft: s.attemptsLeft,
      onUnlocked: () => setState(() => _unlocked = true),
    );
  }

  Widget _retryButton(String label, {required VoidCallback onPressed}) => FilledButton(
        onPressed: onPressed,
        child: Text(label),
      );
}

/// First sign-in: choose a PIN, twice. This is the ONLY place a PIN is chosen — an
/// administrator can clear it but can never set one, so nobody else ever knows it.
class SetPinScreen extends StatefulWidget {
  const SetPinScreen({super.key, required this.token, required this.onDone});

  final String token;
  final VoidCallback onDone;

  @override
  State<SetPinScreen> createState() => _SetPinScreenState();
}

class _SetPinScreenState extends State<SetPinScreen> {
  final PatrolClient _client = PatrolClient();
  String _pin = '';
  String _confirm = '';
  bool _busy = false;
  String? _err;

  bool get _mismatch => _confirm.isNotEmpty && _pin != _confirm;
  bool get _ready => _pin.length >= 4 && _pin.length <= 8 && _pin == _confirm && !_busy;

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _err = null;
    });
    final fail = await _client.setPin(widget.token, _pin);
    if (!mounted) return;
    setState(() => _busy = false);
    if (fail == null) {
      widget.onDone();
    } else {
      setState(() => _err = fail);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PinScaffold(
      title: 'Set your monitor PIN',
      blurb: "You'll enter this each time you start monitoring, on top of your "
          "password. It keeps your ticks yours — nobody who learns your password can file a "
          "monitor record as you. Choose 4 to 8 digits you won't write down.",
      child: Column(
        children: [
          PinField('New PIN', _pin, (v) => setState(() => _pin = v)),
          const SizedBox(height: 10),
          PinField('Confirm PIN', _confirm, (v) => setState(() => _confirm = v),
              isError: _mismatch),
          if (_mismatch)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text("The two PINs don't match.",
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                  textAlign: TextAlign.center),
            ),
          if (_err != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_err!,
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                      fontSize: 14)),
            ),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _ready ? _save : null,
              child: Text(_busy ? 'Saving…' : 'Save PIN and start monitoring'),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Forgotten it later? An administrator can clear it so you can set a new '
            "one. They can't see or choose it.",
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 20),
          const SignOutButton(),
        ],
      ),
    );
  }
}

/// Every sign-in after the first.
class EnterPinScreen extends StatefulWidget {
  const EnterPinScreen({
    super.key,
    required this.token,
    required this.initiallyLocked,
    required this.attemptsLeft,
    required this.onUnlocked,
  });

  final String token;
  final bool initiallyLocked;
  final int attemptsLeft;
  final VoidCallback onUnlocked;

  @override
  State<EnterPinScreen> createState() => _EnterPinScreenState();
}

class _EnterPinScreenState extends State<EnterPinScreen> {
  final PatrolClient _client = PatrolClient();
  String _pin = '';
  bool _busy = false;
  String? _err;
  late int _left = widget.attemptsLeft;
  late bool _locked = widget.initiallyLocked;

  Future<void> _verify() async {
    setState(() {
      _busy = true;
      _err = null;
    });
    final res = await _client.verifyPin(widget.token, _pin);
    if (!mounted) return;
    setState(() => _busy = false);
    if (res.ok) {
      widget.onUnlocked();
    } else if (res.locked) {
      setState(() {
        _locked = true;
        _pin = '';
      });
    } else {
      setState(() {
        _err = res.message;
        _left = res.attemptsLeft;
        _pin = '';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_locked) {
      return PinMessageScreen(
        title: 'Monitoring is locked',
        body: 'Too many wrong PINs. Wait a little and try again, or ask an '
            'administrator to clear your PIN so you can set a new one.',
        child: FilledButton(
          onPressed: () => setState(() {
            _locked = false;
            _err = null;
            _left = 5;
          }),
          child: const Text('Try again'),
        ),
      );
    }

    return PinScaffold(
      title: 'Enter your monitor PIN',
      blurb: "One more step before today's round.",
      child: Column(
        children: [
          PinField('PIN', _pin, (v) => setState(() => _pin = v), isError: _err != null),
          if (_err != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Column(children: [
                Text(_err!,
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontSize: 14),
                    textAlign: TextAlign.center),
                if (_left >= 1 && _left <= 2)
                  Text('$_left ${_left == 1 ? 'try' : 'tries'} left before monitoring locks.',
                      style: TextStyle(color: Theme.of(context).colorScheme.error),
                      textAlign: TextAlign.center),
              ]),
            ),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _pin.length >= 4 && !_busy ? _verify : null,
              child: Text(_busy ? 'Checking…' : 'Start monitoring'),
            ),
          ),
          const SizedBox(height: 20),
          const SignOutButton(),
        ],
      ),
    );
  }
}

/// Change the PIN from the Profile tab. The CURRENT one is required — the round is
/// already open at this point, so without it a handset left unlocked for a minute
/// would be enough to take the account by simply replacing its second factor.
class ChangePatrolPinDialog extends StatefulWidget {
  const ChangePatrolPinDialog({super.key, required this.token, required this.onClose});

  final String token;
  final VoidCallback onClose;

  @override
  State<ChangePatrolPinDialog> createState() => _ChangePatrolPinDialogState();
}

class _ChangePatrolPinDialogState extends State<ChangePatrolPinDialog> {
  final PatrolClient _client = PatrolClient();
  String _current = '';
  String _next = '';
  String _confirm = '';
  bool _busy = false;
  String? _err;
  bool _done = false;

  bool get _mismatch => _confirm.isNotEmpty && _next != _confirm;
  bool get _ready =>
      _current.length >= 4 &&
      _next.length >= 4 &&
      _next.length <= 8 &&
      _next == _confirm &&
      !_busy;

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _err = null;
    });
    final fail = await _client.setPin(widget.token, _next, currentPin: _current);
    if (!mounted) return;
    setState(() => _busy = false);
    if (fail == null) {
      setState(() => _done = true);
    } else {
      setState(() => _err = fail);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(_done ? 'PIN changed' : 'Change monitor PIN'),
      content: _done
          ? const Text('Your new PIN applies the next time you start monitoring.')
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                PinField('Current PIN', _current, (v) => setState(() => _current = v)),
                const SizedBox(height: 8),
                PinField('New PIN', _next, (v) => setState(() => _next = v)),
                const SizedBox(height: 8),
                PinField('Confirm new PIN', _confirm, (v) => setState(() => _confirm = v),
                    isError: _mismatch),
                if (_mismatch)
                  Text("The two PINs don't match.",
                      style: TextStyle(color: theme.colorScheme.error),
                      textAlign: TextAlign.center),
                if (_err != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(_err!,
                        style: TextStyle(color: theme.colorScheme.error, fontSize: 14)),
                  ),
              ],
            ),
      actions: [
        if (!_done)
          TextButton(onPressed: widget.onClose, child: const Text('Cancel')),
        TextButton(
          onPressed: _done
              ? widget.onClose
              : (_ready ? _save : null),
          child: Text(_done ? 'Done' : (_busy ? 'Saving…' : 'Save')),
        ),
      ],
    );
  }
}

// ── Shared chrome ────────────────────────────────────────────────────────────

/// The PIN screens' shared, centered scaffold: logo, shield, title, blurb, body.
class PinScaffold extends StatelessWidget {
  const PinScaffold({super.key, required this.title, required this.blurb, this.child});

  final String title;
  final String blurb;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: ConstrainedBox(
            constraints: BoxConstraints(
                minHeight: MediaQuery.sizeOf(context).height - 56),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(child: BrandLogo(branding: BrandingState.current.value, size: 56)),
                    const SizedBox(height: 16),
                    const Center(child: Text('🛡', style: TextStyle(fontSize: 30))),
                    const SizedBox(height: 8),
                    Text(title,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.titleLarge
                            ?.copyWith(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Text(blurb,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                    const SizedBox(height: 22),
                    ?child,
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A PIN field that only ever holds up to 8 digits — filtered at the source, so the
/// monitor never gets "digits only" back from a round trip.
class PinField extends StatefulWidget {
  const PinField(this.label, this.value, this.onChange, {super.key, this.isError = false});

  final String label;
  final String value;
  final ValueChanged<String> onChange;
  final bool isError;

  @override
  State<PinField> createState() => _PinFieldState();
}

class _PinFieldState extends State<PinField> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.value);

  @override
  void didUpdateWidget(PinField old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value && _controller.text != widget.value) {
      _controller.text = widget.value;
      _controller.selection = TextSelection.collapsed(offset: widget.value.length);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      // The formatters do the digit-filtering and the 8-char cap, so the value a
      // parent sees via onChanged can never hold something the server rejects.
      onChanged: widget.onChange,
      keyboardType: TextInputType.number,
      obscureText: true,
      inputFormatters: [
        FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(8),
      ],
      decoration: InputDecoration(
        labelText: widget.label,
        border: const OutlineInputBorder(),
        errorText: widget.isError ? ' ' : null,
      ),
      style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
    );
  }
}

/// A message page inside the PIN chrome, with a single primary action.
class PinMessageScreen extends StatelessWidget {
  const PinMessageScreen({
    super.key,
    required this.title,
    required this.body,
    required this.child,
  });

  final String title;
  final String body;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return PinScaffold(
      title: title,
      blurb: body,
      child: Column(children: [
        child,
        const SizedBox(height: 20),
        const SignOutButton(),
      ]),
    );
  }
}