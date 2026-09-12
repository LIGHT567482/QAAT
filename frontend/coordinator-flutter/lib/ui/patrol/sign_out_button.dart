import 'package:flutter/material.dart';

import '../../net/session_store.dart';
import '../../patrol/patrol_store.dart';

/// The sign-out control every monitor screen uses.
///
/// Sign-out for the monitor is not "forget the token". A monitor log names
/// lecturers, and on a shared or surrendered handset it must not outlive the sign-in
/// that produced it — so the teardown wipes the ENTIRE offline store (slots, logs,
/// people, visits) before routing back to the login screen.
///
/// And because those queued ticks are lost with the account, the button refuses to
/// vanish silently: when observations have not reached the server yet, it says so
/// and asks before the user trades a soft "sign out" for a hard data loss.
class SignOutButton extends StatefulWidget {
  const SignOutButton({super.key, this.label = 'Sign out'});

  final String label;

  @override
  State<SignOutButton> createState() => _SignOutButtonState();
}

class _SignOutButtonState extends State<SignOutButton> {
  bool _checking = false;
  bool _confirming = false;
  int _pending = 0;
  String? _blocked;

  Future<void> _pressed() async {
    setState(() => _blocked = null);
    // Counting pending uploads touches the store, so it happens once on press.
    setState(() => _checking = true);
    final n = await patrolStore.pendingSyncCount();
    if (!mounted) return;
    setState(() => _checking = false);
    if (n > 0) {
      setState(() {
        _pending = n;
        _confirming = true;
      });
    } else {
      await _signOut();
    }
  }

  Future<void> _signOut() async {
    await patrolStore.clearAllForSignOut();
    // Forget the saved credential too, so a shared handset never boots the next
    // user straight back into the previous monitor's session.
    await SessionStore.clear();
    if (!mounted) return;
    Navigator.of(context).pushNamedAndRemoveUntil('/login', (_) => false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(children: [
      OutlinedButton(
        onPressed: _checking ? null : _pressed,
        child: Text(widget.label, style: TextStyle(color: theme.colorScheme.error)),
      ),
      if (_blocked != null)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(_blocked!,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.error)),
        ),
      if (_confirming)
        AlertDialog(
          title: const Text('Round not uploaded'),
          content: Text(
            '$_pending ${_pending == 1 ? 'observation has' : 'observations have'} '
            'not reached the server yet. Signing out discards '
            '${_pending == 1 ? 'it' : 'them'} — what you recorded in the round lives '
            'on this phone until it syncs.\n\nGet online and let it sync first if you can.',
          ),
          actions: [
            TextButton(
              onPressed: () => setState(() => _confirming = false),
              child: const Text('Stay signed in'),
            ),
            TextButton(
              onPressed: () {
                setState(() => _confirming = false);
                _signOut();
              },
              child:
                  Text('Sign out anyway', style: TextStyle(color: theme.colorScheme.error)),
            ),
          ],
        ),
    ]);
  }
}