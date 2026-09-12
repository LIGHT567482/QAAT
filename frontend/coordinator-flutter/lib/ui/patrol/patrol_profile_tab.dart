import 'package:flutter/material.dart';

import '../../net/auth_client.dart';
import '../change_password_screen.dart';
import 'pin_gate.dart';
import 'sign_out_button.dart';

/// The monitor's Profile tab: who is on this handset, which handset is registered,
/// and the account's two secrets — the password, and the monitor PIN.
class PatrolProfileTab extends StatefulWidget {
  const PatrolProfileTab({
    super.key,
    required this.token,
    this.fullName = '',
    this.staffId = '',
  });

  final String token;
  final String fullName;
  final String staffId;

  @override
  State<PatrolProfileTab> createState() => _PatrolProfileTabState();
}

class _PatrolProfileTabState extends State<PatrolProfileTab> {
  bool _changePin = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurfaceVariant;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Profile',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          if (widget.fullName.isNotEmpty)
            Text(widget.fullName,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w600)),
          if (widget.staffId.isNotEmpty)
            Text('Staff ID: ${widget.staffId}',
                style: theme.textTheme.bodySmall?.copyWith(color: onSurface)),
          Text('QA Monitor',
              style: theme.textTheme.bodySmall?.copyWith(color: onSurface)),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              'This phone is registered to your monitor account. Rounds recorded '
              'on any other handset are rejected.',
              style: theme.textTheme.bodySmall,
            ),
          ),
          const SizedBox(height: 24),
          OutlinedButton(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => ChangePasswordScreen(
                auth: const AuthClient(),
                token: widget.token,
                onChanged: () => Navigator.of(context).pop(),
              ),
            )),
            child: const Text('🔑  Change password'),
          ),
          const SizedBox(height: 8),
          // The PIN is changed from inside the round, where the monitor has already
          // proved they know the current one — so a handset left unlocked cannot be
          // used to replace it.
          OutlinedButton(
            onPressed: () => setState(() => _changePin = true),
            child: const Text('🛡  Change monitor PIN'),
          ),
          if (_changePin)
            ChangePatrolPinDialog(
              token: widget.token,
              onClose: () => setState(() => _changePin = false),
            ),
          const SizedBox(height: 8),
          const SignOutButton(),
        ],
      ),
    );
  }
}