import 'package:flutter/material.dart';

import '../../net/auth_client.dart';
import '../../net/coordinator_client.dart';
import '../../patrol/notification_client.dart';
import 'app_state.dart';
import 'open_register_screen.dart';
import 'standby_card.dart';

/// The in-room screen — a faithful port of the native `SessionScreen`: the big
/// code students type, the live "present" feed, the broadcast box and the end
/// button, plus the idle entry (Take attendance + Emergency standby). Reloads on
/// every ⟳ so the live count tracks the server.
class CoordinatorSessionTab extends StatefulWidget {
  const CoordinatorSessionTab({super.key, required this.result, this.client});

  final LoginResult result;
  final CoordinatorClient? client;

  @override
  State<CoordinatorSessionTab> createState() => _CoordinatorSessionTabState();
}

class _CoordinatorSessionTabState extends State<CoordinatorSessionTab> {
  late final CoordinatorClient _client = widget.client ?? const CoordinatorClient();
  final _local = ValueNotifier<int>(0);

  LoginResult get _r => widget.result;

  @override
  void initState() {
    super.initState();
    CoordinatorState.refreshTick.addListener(_bump);
  }

  @override
  void dispose() {
    CoordinatorState.refreshTick.removeListener(_bump);
    _local.dispose();
    super.dispose();
  }

  void _bump() {
    if (mounted) _local.value++;
  }

  Future<void> _openRegister() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => OpenRegisterScreen(token: _r.token, client: _client),
      ),
    );
    if (mounted) _bump();
  }

  Future<void> _announce(String msg) async {
    final outcome = await (NotificationClient()).send(
      _r.token,
      audience: 'STUDENTS',
      subject: 'Message from your coordinator',
      body: msg,
    );
    if (outcome.error != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(outcome.error!)),
      );
    }
  }

  void _endSession() {
    CoordinatorState.clearOpenRegister();
    _bump();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: _local,
      builder: (context, _, _) {
        final today = CoordinatorState.todaySession.value;
        if (today == null) return _AttendanceIdle(result: _r, onOpen: _openRegister);
        return _LiveSession(
          result: _r,
          session: today,
          onEnd: _endSession,
          onAnnounce: _announce,
        );
      },
    );
  }
}

/// No register open on this phone yet: the Attendance entry + Emergency standby.
class _AttendanceIdle extends StatelessWidget {
  const _AttendanceIdle({required this.result, required this.onOpen});

  final LoginResult result;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Attendance',
          style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
        ),
        ValueListenableBuilder<String?>(
          valueListenable: CoordinatorState.sessionNotice,
          builder: (context, note, _) {
            if (note == null) return const SizedBox.shrink();
            return Card(
              color: scheme.tertiaryContainer,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(note, style: theme.textTheme.bodySmall),
                    ),
                    TextButton(
                      onPressed: () => CoordinatorState.sessionNotice.value = null,
                      child: const Text('Dismiss'),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
        Text(
          'Start a session so students can check in — this works even with no '
          'internet once today\'s data is downloaded.',
          style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: onOpen,
          child: const Text('Take attendance', style: TextStyle(fontWeight: FontWeight.bold)),
        ),
        const SizedBox(height: 20),
        StandbyCard(token: result.token),
      ],
    );
  }
}

/// A register is open here: the code panel, live feed, announcement + End.
class _LiveSession extends StatelessWidget {
  const _LiveSession({
    required this.result,
    required this.session,
    required this.onEnd,
    required this.onAnnounce,
  });

  final LoginResult result;
  final TodaySession session;
  final VoidCallback onEnd;
  final Future<void> Function(String msg) onAnnounce;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final cohort = CoordinatorState.cohortLabel.value;

    final active = CoordinatorState.activeSessions.value
        .where((s) => s.sessionId == session.sessionId)
        .toList();
    final present = active.isEmpty ? 0 : active.first.presentCount;

    final spacedCode = session.studentCode.split('').join('  ');

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (cohort != null && cohort.isNotEmpty) ...[
                Text(
                  cohort,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
              ],
              Card(
                color: scheme.inverseSurface,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      Text(
                        'STUDENTS: OPEN THE QAAT APP, TAP ATTEND, AND TYPE THIS CODE',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onInverseSurface,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        session.studentCode.isEmpty ? 'opening…' : spacedCode,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          color: scheme.onInverseSurface,
                          fontWeight: FontWeight.bold,
                          fontFamily: 'monospace',
                        ),
                      ),
                      if (session.windowEnd.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          'Closes at ${_friendlyTime(session.windowEnd)}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onInverseSurface,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton.tonal(
                onPressed: () => _showLiveRoster(context, present),
                child: Text(
                  'View live roster — $present present',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: _AnnounceRow(onSend: onAnnounce),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: OutlinedButton.icon(
            onPressed: onEnd,
            icon: const Icon(Icons.stop, size: 18),
            label: const Text('End session + sync'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(44),
            ),
          ),
        ),
      ],
    );
  }

  String _friendlyTime(String iso) {
    final t = DateTime.tryParse(iso)?.toLocal();
    if (t == null) return iso;
    return '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}';
  }
}

void _showLiveRoster(BuildContext context, int present) {
  showDialog<void>(
    context: context,
    builder: (context) {
      final theme = Theme.of(context);
      return AlertDialog(
        title: Text('Live roster — $present present'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'The roll-call view (who exactly) arrives with student check-in — '
                'currently, the count updates here and the sealed roster shows on '
                'Home once the session closes.',
                textAlign: TextAlign.center,
              ),
              Text(
                'Students checked in so far: $present',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      );
    },
  );
}

class _AnnounceRow extends StatefulWidget {
  const _AnnounceRow({required this.onSend});

  final void Function(String msg) onSend;

  @override
  State<_AnnounceRow> createState() => _AnnounceRowState();
}

class _AnnounceRowState extends State<_AnnounceRow> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _controller,
            decoration: const InputDecoration(
              isDense: true,
              hintText: 'Announcement…',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        const SizedBox(width: 8),
        FilledButton(
          onPressed: () {
            final m = _controller.text.trim();
            if (m.isEmpty) return;
            widget.onSend(m);
            _controller.clear();
          },
          child: const Text('Send'),
        ),
      ],
    );
  }
}