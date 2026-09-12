import 'package:flutter/material.dart';

import '../../net/portal_client.dart';
import '../../patrol/notification_client.dart';
import '../../patrol/patrol_models.dart';
import 'manual_attendance_sheet.dart' show PickOrType;

/// One alert, drawn the same way in every inbox — student, lecturer and
/// coordinator. Three things every alert carries: WHO sent it (with their role),
/// WHEN (a friendly relative age plus the exact date and time, because "2h ago"
/// alone is useless when reconciling an attendance dispute a week later), and an ✕
/// that removes it from YOUR inbox — other recipients keep theirs.
class NotificationCard extends StatefulWidget {
  const NotificationCard({
    super.key,
    required this.notif,
    required this.onOpen,
    required this.onDismiss,
  });

  final Notif notif;
  final VoidCallback onOpen;
  final VoidCallback onDismiss;

  @override
  State<NotificationCard> createState() => _NotificationCardState();
}

class _NotificationCardState extends State<NotificationCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final n = widget.notif;
    return Material(
      color: n.read
          ? theme.colorScheme.surfaceContainerHighest
          : theme.colorScheme.primary.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          setState(() => _expanded = !_expanded);
          widget.onOpen();
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      n.subject,
                      style: TextStyle(
                        fontWeight: n.read ? FontWeight.w600 : FontWeight.bold,
                      ),
                    ),
                    Text(
                      'from ${n.senderName} · ${n.senderRole.replaceAll('_', ' ')}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    Text(
                      formatSentAt(n.createdAt),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontSize: 11,
                      ),
                    ),
                    if (_expanded && n.body.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(n.body),
                    ],
                  ],
                ),
              ),
              IconButton(
                onPressed: widget.onDismiss,
                icon: Icon(
                  Icons.close,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                tooltip: 'Dismiss this alert',
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "2h ago · Mon 12 Aug 2026, 14:05" — relative for scanning, absolute for the
/// record.
String formatSentAt(String iso) {
  final instant = DateTime.tryParse(iso)?.toUtc();
  if (instant == null) return iso;
  final local = instant.toLocal();
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  final exact =
      '${days[local.weekday - 1]} ${local.day} '
      '${months[local.month - 1]} ${local.year}, '
      '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';

  final mins = DateTime.now().toUtc().difference(instant).inMinutes;
  final rel = switch (mins) {
    < 1 => 'just now',
    < 60 => '${mins}m ago',
    < 60 * 24 => '${mins ~/ 60}h ago',
    < 60 * 24 * 7 => '${mins ~/ (60 * 24)}d ago',
    _ => null,
  };
  return rel == null ? exact : '$rel · $exact';
}

/// Inbox AND a composer. A monitor rarely needs to write to staff — the round is
/// the message — but two situations genuinely need the composer: flagging an empty
/// room to the ONE coordinator who owns it (the singular COORDINATOR audience, by
/// user id), and a briefing to their own team of monitors ("round 2 rooms moved").
/// The audiences offered here are exactly the ones the gateway lets a QA sender use,
/// and each send reports how many active accounts actually received it.
enum _InboxFilter { all, unread }

class PatrolAlertsTab extends StatefulWidget {
  const PatrolAlertsTab({super.key, required this.token});

  final String token;

  @override
  State<PatrolAlertsTab> createState() => _PatrolAlertsTabState();
}

class _PatrolAlertsTabState extends State<PatrolAlertsTab> {
  final NotificationClient _client = const NotificationClient();
  List<Notif>? _inbox; // null = still loading
  // Ids the server has ACCEPTED a dismissal for, plus the ones still in flight. Held
  // here so the ✕ feels instant and, more importantly, the card stays gone across the
  // refresh that follows it.
  final List<String> _dismissed = [];
  String? _dismissError;
  bool _onlyUnread = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final inbox = await _client.inbox(widget.token);
    if (!mounted) return;
    setState(() => _inbox = inbox);
  }

  void _markRead(Notif n) async {
    if (n.read) return;
    await _client.markRead(widget.token, n.id);
    if (!mounted) return;
    _load();
  }

  void _dismiss(Notif n) async {
    setState(() {
      _dismissed.add(n.id);
      _dismissError = null;
    });
    final err = await _client.dismiss(widget.token, n.id);
    if (!mounted) return;
    if (err != null) {
      setState(() {
        _dismissed.remove(n.id); // it is still in the inbox; say so
        _dismissError = err;
      });
    }
    _load();
  }

  Future<void> _openComposer() async {
    final recipients = await showModalBottomSheet<int?>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ComposerSheet(token: widget.token),
    );
    if (recipients == null || !mounted) return;
    _load();
    final who = recipients == 1 ? 'recipient' : 'recipients';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Sent to $recipients $who.'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = _inbox;
    final visible = items
        ?.where((n) => !_dismissed.contains(n.id))
        .where((n) => !_onlyUnread || !n.read)
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Notifications',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            PopupMenuButton<_InboxFilter>(
              tooltip: 'Filter',
              icon: const Icon(Icons.filter_list),
              onSelected: (f) =>
                  setState(() => _onlyUnread = f == _InboxFilter.unread),
              itemBuilder: (_) => const [
                PopupMenuItem(value: _InboxFilter.all, child: Text('All')),
                PopupMenuItem(
                  value: _InboxFilter.unread,
                  child: Text('Unread only'),
                ),
              ],
            ),
            IconButton(
              icon: const Icon(Icons.add_comment_outlined),
              tooltip: 'Compose',
              onPressed: _openComposer,
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (_dismissError != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              _dismissError!,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
        Expanded(
          child: switch (items) {
            null => const Center(
              child: Padding(
                padding: EdgeInsets.only(top: 30),
                child: CircularProgressIndicator(),
              ),
            ),
            _ when (visible == null || visible.isEmpty) => Padding(
              padding: const EdgeInsets.only(top: 20),
              child: Text(
                _onlyUnread ? 'Nothing unread.' : 'No notifications yet.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            _ => ListView.separated(
              itemCount: visible.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (_, i) => NotificationCard(
                notif: visible[i],
                onOpen: () => _markRead(visible[i]),
                onDismiss: () => _dismiss(visible[i]),
              ),
            ),
          },
        ),
      ],
    );
  }
}

/// The compose sheet. Sends through the same gateway validation as every other
/// client: [NotificationClient.send], whose refusal words it shows verbatim.
class _ComposerSheet extends StatefulWidget {
  const _ComposerSheet({required this.token});

  final String token;

  @override
  State<_ComposerSheet> createState() => _ComposerSheetState();
}

class _ComposerSheetState extends State<_ComposerSheet> {
  static const _audiences = <(String, String)>[
    ('MONITORS', 'Monitors (all)'),
    ('COORDINATORS', 'All coordinators'),
    ('COORDINATOR', 'One coordinator'),
    ('LECTURERS', 'Lecturers (all)'),
  ];

  final _subject = TextEditingController();
  final _body = TextEditingController();

  String _audience = 'MONITORS';
  List<CoordinatorEntry>? _coordinators; // null = still loading
  String _coordinatorId = '';
  String _coordinatorTyped = '';
  bool _sending = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadCoordinators();
  }

  Future<void> _loadCoordinators() async {
    final cs = await const PortalClient().patrolCoordinators(widget.token);
    if (!mounted) return;
    setState(() => _coordinators = cs ?? const []);
  }

  Future<void> _send() async {
    if (_sending) return;
    final subject = _subject.text.trim();
    final body = _body.text.trim();
    if (subject.isEmpty || body.isEmpty) {
      setState(() => _error = 'Both a subject and a message are required.');
      return;
    }
    if (_audience == 'COORDINATOR' && _coordinatorId.isEmpty) {
      setState(
        () => _error =
            'Pick a coordinator from the list, or choose a different audience.',
      );
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    final out = await NotificationClient().send(
      widget.token,
      audience: _audience,
      targetId: _audience == 'COORDINATOR' ? _coordinatorId : null,
      subject: subject,
      body: body,
    );
    if (!mounted) return;
    if (out.error != null) {
      setState(() {
        _sending = false;
        _error = out.error;
      });
      return;
    }
    final n = out.recipients;
    Navigator.of(context).pop(n);
  }

  @override
  void dispose() {
    _subject.dispose();
    _body.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isSingular = _audience == 'COORDINATOR';
    final coordinatorOptions =
        _coordinators
            ?.map((c) => RefItem(c.userId, c.fullName, c.department))
            .toList() ??
        const <RefItem>[];
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Compose notification',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            Text('Send to', style: theme.textTheme.labelMedium),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final (value, label) in _audiences)
                  ChoiceChip(
                    label: Text(label),
                    selected: _audience == value,
                    onSelected: (_) => setState(() => _audience = value),
                  ),
              ],
            ),
            if (isSingular) ...[
              const SizedBox(height: 6),
              if (_coordinators == null)
                const LinearProgressIndicator()
              else
                PickOrType(
                  label: 'Coordinator',
                  options: coordinatorOptions,
                  selectedId: _coordinatorId,
                  typed: _coordinatorTyped,
                  onPick: (c) => setState(() {
                    _coordinatorId = c?.id ?? '';
                    _coordinatorTyped = c?.label ?? '';
                  }),
                  onType: (v) => setState(() {
                    _coordinatorTyped = v;
                    _coordinatorId = '';
                  }),
                  note: coordinatorOptions.isEmpty
                      ? 'No coordinators are on file.'
                      : null,
                ),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: _subject,
              enabled: !_sending,
              decoration: const InputDecoration(
                labelText: 'Subject',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _body,
              enabled: !_sending,
              minLines: 3,
              maxLines: 6,
              decoration: const InputDecoration(
                labelText: 'Message',
                alignLabelWithHint: true,
                border: OutlineInputBorder(),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: _sending ? null : _send,
                    child: Text(_sending ? 'Sending…' : 'Send'),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: _sending
                      ? null
                      : () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
