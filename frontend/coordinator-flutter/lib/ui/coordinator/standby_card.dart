import 'package:flutter/material.dart';

import '../../net/coordinator_client.dart';

/// Emergency standby — a faithful port of the native `StandbyCard`: a genuine
/// absence hands a student from the coordinator's OWN cohort a code that lets
/// them run the session today. The QA monitor side of the ledger reads it as a
/// legitimate session rather than as a lecturer not teaching.
class StandbyCard extends StatefulWidget {
  const StandbyCard({
    super.key,
    required this.token,
    this.client,
  });

  final String token;
  final CoordinatorClient? client;

  @override
  State<StandbyCard> createState() => _StandbyCardState();
}

class _StandbyCardState extends State<StandbyCard> {
  late final CoordinatorClient _client = widget.client ?? const CoordinatorClient();
  var _open = false;
  var _list = <Standby>[];
  var _reg = '';
  var _busy = false;
  String? _err;

  Future<void> _reload() async {
    if (widget.token.isEmpty) return;
    final list = await _client.standby(widget.token);
    if (mounted) setState(() => _list = list);
  }

  Future<void> _issue() async {
    setState(() {
      _busy = true;
      _err = null;
    });
    final err = await _client.issueStandby(widget.token, _reg.trim());
    if (err == null) {
      _reg = '';
      await _reload();
    }
    if (mounted) {
      setState(() {
        _err = err;
        _busy = false;
      });
    }
  }

  Future<void> _revoke(String id) async {
    await _client.revokeStandby(widget.token, id);
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              onTap: () => setState(() => _open = !_open),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '🆘 Emergency standby'
                      '${_list.isNotEmpty ? ' · ${_list.length} active' : ''}',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  Text(
                    _open ? '▾' : '▸',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            if (_open) ...[
              const SizedBox(height: 8),
              Text(
                'Going to be absent? Authorise a student from your OWN cohort to '
                'run the session today. Read them the code — they sign in with '
                'the standby code. Valid until end of day.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              if (_err != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    _err!,
                    style: TextStyle(color: scheme.error, fontSize: 12),
                  ),
                ),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      onChanged: (v) => setState(() => _reg = v),
                      decoration: const InputDecoration(
                        isDense: true,
                        hintText: "Standby student's reg no.",
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _busy || _reg.trim().isEmpty ? null : _issue,
                    child: Text(_busy ? '…' : 'Issue'),
                  ),
                ],
              ),
              for (final s in _list)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              s.code,
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontWeight: FontWeight.w800,
                                fontSize: 16,
                              ),
                            ),
                            Text(
                              s.deputyName.isNotEmpty ? s.deputyName : s.deputyReg,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      TextButton(
                        onPressed: () => _revoke(s.id),
                        child: const Text('Revoke'),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}