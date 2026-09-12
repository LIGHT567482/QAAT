import 'package:flutter/material.dart';

import '../../net/auth_client.dart';
import '../../net/coordinator_client.dart';
import '../../patrol/notification_client.dart';
import '../patrol/patrol_alerts_tab.dart' show NotificationCard;

/// Coordinator notifications — a faithful port of the native
/// `CoordinatorAlertsScreen`: an inbox of sent/received messages and a composer
/// addressed to the coordinator's course's lecturers (all or one). The student
/// audiences are deferred to V2 exactly as they are in the native app.
class CoordinatorAlertsTab extends StatefulWidget {
  const CoordinatorAlertsTab({super.key, required this.result, this.client});

  final LoginResult result;
  final CoordinatorClient? client;

  @override
  State<CoordinatorAlertsTab> createState() => _CoordinatorAlertsTabState();
}

class _CoordinatorAlertsTabState extends State<CoordinatorAlertsTab> {
  late final CoordinatorClient _client = widget.client ?? const CoordinatorClient();
  var _inbox = <Notif>[];
  var _busy = true;
  var _composing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    final list = await NotificationClient().inbox(widget.result.token);
    if (mounted) {
      setState(() {
        _inbox = list;
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Notifications',
                style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),
            FilledButton.tonal(
              onPressed: () => setState(() => _composing = !_composing),
              child: Text(_composing ? 'Close' : '✎ New'),
            ),
          ],
        ),
        if (_composing)
          _Composer(
            token: widget.result.token,
            client: _client,
            onSent: () {
              setState(() => _composing = false);
              _load();
            },
          ),
        const SizedBox(height: 8),
        if (_busy)
          const Padding(
            padding: EdgeInsets.only(top: 24),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_inbox.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Text(
              'No alerts yet. One arrives when a lecturer disputes a patrolled '
              'observation, or when the QA office announces something to your cohort.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          )
        else
          for (final n in _inbox)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: NotificationCard(
                notif: n,
                onOpen: () {
                  if (!n.read) {
                    NotificationClient().markRead(widget.result.token, n.id);
                    // Best-effort: keep it bold until the read lands.
                  }
                },
                onDismiss: () async {
                  final err = await NotificationClient()
                      .dismiss(widget.result.token, n.id);
                  if (err == null) _load();
                },
              ),
            ),
      ],
    );
  }
}

/// The composer card: audience chips (all lecturers / a lecturer) + optional
/// picker + subject + message + Send.
class _Composer extends StatefulWidget {
  const _Composer({
    required this.token,
    required this.client,
    required this.onSent,
  });

  final String token;
  final CoordinatorClient client;
  final VoidCallback onSent;

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  var _audience = 'LECTURERS';
  String? _targetId;
  String _subject = '';
  String _body = '';
  var _busy = false;
  String? _err;
  var _lecturers = <CoordLecturer>[];

  @override
  void initState() {
    super.initState();
    _loadPickers();
  }

  Future<void> _loadPickers() async {
    final l = await widget.client.lecturers(widget.token);
    if (mounted) setState(() => _lecturers = l);
  }

  Future<void> _send() async {
    setState(() {
      _busy = true;
      _err = null;
    });
    final outcome = await (NotificationClient()).send(
      widget.token,
      audience: _audience,
      targetId: _targetId,
      subject: _subject,
      body: _body,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _err = outcome.error;
    });
    if (outcome.error == null) widget.onSent();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilterChip(
                  label: const Text('All lecturers', style: TextStyle(fontSize: 12)),
                  selected: _audience == 'LECTURERS',
                  onSelected: (_) => setState(() => _audience = 'LECTURERS'),
                ),
                FilterChip(
                  label: const Text('A lecturer', style: TextStyle(fontSize: 12)),
                  selected: _audience == 'LECTURER',
                  onSelected: (_) => setState(() {
                    _audience = 'LECTURER';
                    _targetId = null;
                  }),
                ),
              ],
            ),
            if (_audience == 'LECTURER') ...[
              const SizedBox(height: 6),
              DropdownButton<String>(
                value: _targetId,
                isExpanded: true,
                hint: const Text('Pick a lecturer'),
                items: [
                  for (final l in _lecturers)
                    DropdownMenuItem(value: l.lecturerId, child: Text(l.fullName)),
                ],
                onChanged: (v) {
                  setState(() => _targetId = v);
                },
              ),
            ],
            if (_err != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(_err!, style: TextStyle(color: scheme.error, fontSize: 12)),
              ),
            const SizedBox(height: 6),
            TextField(
              onChanged: (v) => setState(() => _subject = v),
              decoration: const InputDecoration(
                isDense: true,
                labelText: 'Subject',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 6),
            TextField(
              onChanged: (v) => setState(() => _body = v),
              minLines: 3,
              maxLines: 6,
              decoration: const InputDecoration(
                labelText: 'Message',
                alignLabelWithHint: true,
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: _busy ||
                      _subject.trim().isEmpty ||
                      (_audience == 'LECTURER' && _targetId == null)
                  ? null
                  : _send,
              child: Text(_busy ? 'Sending…' : 'Send'),
            ),
            if (_subject.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Sent to active accounts only — a lecturer who is not signed '
                  'in gets it when they next open the app.',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}