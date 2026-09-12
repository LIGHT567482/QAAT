import 'package:flutter/material.dart';

import '../../net/auth_client.dart';
import '../../net/coordinator_client.dart';
import 'app_state.dart';

/// Sync audit — a port of the native `SyncAuditScreen`'s read of recent sessions
/// and their sync status.
///
/// The native screen reads the phone's own Room ledger of completed sessions and
/// whether each one uploaded. This cloud-driven build holds no offline session
/// queue (attendance is written to the server live), so the same "what has been
/// recorded" view is drawn from the gateway's own record: sections in progress
/// (with their live check-in count) and the last sealed, synced roster.
class SyncAuditTab extends StatefulWidget {
  const SyncAuditTab({super.key, required this.result, this.client});

  final LoginResult result;
  final CoordinatorClient? client;

  @override
  State<SyncAuditTab> createState() => _SyncAuditTabState();
}

class _SyncAuditTabState extends State<SyncAuditTab> {
  late final CoordinatorClient _client = widget.client ?? const CoordinatorClient();
  var _active = const <ActiveSession>[];
  var _last = <LastRoster>[];
  var _busy = true;

  @override
  void initState() {
    super.initState();
    _load();
    CoordinatorState.refreshTick.addListener(_load);
  }

  @override
  void dispose() {
    CoordinatorState.refreshTick.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted) return;
    final a = await _client.activeSessions(widget.result.token);
    final last = await _client.lastRoster(widget.result.token);
    if (mounted) {
      setState(() {
        _active = a;
        _last = [?last];
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final rows = _last;
    final empty = _active.isEmpty && rows.isEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Text(
            'Sync audit',
            style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
          ),
        ),
        if (_busy)
          const Padding(
            padding: EdgeInsets.only(top: 24),
            child: LinearProgressIndicator(),
          )
        else if (empty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'No completed attendance to sync yet. Open a register, then close '
              'it here (or from Home) to seal and sync the session.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          )
        else
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              children: [
                if (_active.isNotEmpty)
                  _sectionTitle(theme, scheme, 'In progress'),
                for (final s in _active)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      s.unitName,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(
                      '${_shortId(s.sessionId)} · ${s.presentCount} checked in'),
                    trailing: Text(
                      s.awaitingLecturer ? 'AWAITING LECTURER' : 'LIVE',
                      style: TextStyle(
                        fontSize: 11,
                        color: s.awaitingLecturer ? scheme.error : scheme.primary,
                      ),
                    ),
                  ),
                if (_active.isNotEmpty && rows.isNotEmpty) const Divider(),
                if (rows.isNotEmpty) _sectionTitle(theme, scheme, 'Sealed & synced'),
                for (final r in rows)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      '${r.unitName} · ${r.date}',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text('${r.present}/${r.total} present'),
                    trailing: Text(
                      'SYNCED',
                      style: TextStyle(fontSize: 11, color: scheme.primary),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _sectionTitle(ThemeData theme, ColorScheme scheme, String title) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(
          title,
          style: theme.textTheme.labelSmall?.copyWith(
            color: scheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
      );

  String _shortId(String id) =>
      id.length > 8 ? id.substring(0, 8) : id;
}