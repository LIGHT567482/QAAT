import 'package:flutter/material.dart';

import '../../engine/chronic_absentee.dart';
import '../../net/auth_client.dart';
import '../../net/coordinator_client.dart';
import 'app_state.dart';

T? _firstOrNull<T>(Iterable<T> items) {
  final it = items.iterator;
  return it.moveNext() ? it.current : null;
}

/// Chronic absentees — a port of the native `AbsenteeScreen`'s flagged list and
/// its All / Critical / Warning filters.
///
/// The native screen runs its local `ChronicAbsentee` engine over per-session
/// check-ins held on the phone. This cloud-driven build has no such local store,
/// so it feeds the same `ChronicAbsentee` semantics from the one server-side
/// per-student per-unit summary the gateway exposes (`/coordinator/attendance`):
/// a row whose attendance is BELOW the eligibility threshold is a WARNING, and
/// one in the critically-low band (< the engine's `lowAttendancePct`) is
/// CRITICAL. The "missed N of M sessions" line is the row's own missing count.
class AbsenteesTab extends StatefulWidget {
  const AbsenteesTab({super.key, required this.result, this.client});

  final LoginResult result;
  final CoordinatorClient? client;

  @override
  State<AbsenteesTab> createState() => _AbsenteesTabState();
}

class _AbsenteesTabState extends State<AbsenteesTab> {
  late final CoordinatorClient _client = widget.client ?? const CoordinatorClient();
  var _rows = <AttendanceRow>[];
  var _loading = true;
  String _unitId = '';
  AbsenteeStatus? _filter;

  static const _lowPct = 25.0;

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
    if (!mounted) setState(() {});
    setState(() => _loading = true);
    final r = await _client.attendance(widget.result.token);
    setState(() {
      _rows = r;
      _loading = false;
      if (r.isNotEmpty && !r.any((row) => row.unitId == _unitId)) {
        _unitId = r.first.unitId;
      }
    });
  }

  List<AttendanceRow> get _unitRows {
    final rows = _unitId.isEmpty
        ? _rows
        : _rows.where((r) => r.unitId == _unitId).toList();
    return _filter == null
        ? rows
        : rows.where((r) => _statusOf(r) == _filter).toList();
  }

  AbsenteeStatus _statusOf(AttendanceRow r) {
    if (r.attendancePct < _lowPct) return AbsenteeStatus.critical;
    return AbsenteeStatus.warning;
  }

  List<String> get _unitNames => _rows.map((r) => r.unitId).toSet().toList();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final unitName =
        _firstOrNull(_rows.where((r) => r.unitId == _unitId))?.unitName ?? '';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Text(
            'Chronic absentees',
            style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
          ),
        ),
        if (_rows.isEmpty && !_loading)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'No attendance summary came back. Loaded data only — tap ⟳ when '
              'online and with sessions held.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        if (_unitNames.length > 1)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: DropdownButton<String>(
              value: _unitId,
              isExpanded: true,
              underline: const SizedBox.shrink(),
              items: [
                for (final id in _unitNames)
                  DropdownMenuItem(
                    value: id,
                    child: Text(
                      _firstOrNull(_rows.where((r) => r.unitId == id))?.unitName ?? id,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (v) => setState(() => _unitId = v ?? ''),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Row(
            children: [
              _FilterChipRow(
                label: 'All',
                selected: _filter == null,
                onTap: () => setState(() => _filter = null),
              ),
              const SizedBox(width: 8),
              _FilterChipRow(
                label: 'Critical',
                selected: _filter == AbsenteeStatus.critical,
                onTap: () => setState(() => _filter = AbsenteeStatus.critical),
              ),
              const SizedBox(width: 8),
              _FilterChipRow(
                label: 'Warning',
                selected: _filter == AbsenteeStatus.warning,
                onTap: () => setState(() => _filter = AbsenteeStatus.warning),
              ),
            ],
          ),
        ),
        if (_loading)
          const LinearProgressIndicator()
        else if (_rows.isNotEmpty && _unitRows.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('No flagged students. 🎉'),
          )
        else
          Expanded(
            child: RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                children: [
                  if (unitName.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                      child: Text(
                        unitName,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  for (final r in _unitRows)
                    _FlagRow(
                      row: r,
                      status: _statusOf(r),
                      themed: scheme,
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _FilterChipRow extends StatelessWidget {
  const _FilterChipRow({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FilterChip(
      label: Text(label, style: const TextStyle(fontSize: 12)),
      selected: selected,
      onSelected: (_) => onTap(),
      backgroundColor: null,
      selectedColor: scheme.primary.withValues(alpha: 0.15),
      checkmarkColor: scheme.primary,
    );
  }
}

class _FlagRow extends StatelessWidget {
  const _FlagRow({
    required this.row,
    required this.status,
    required this.themed,
  });

  final AttendanceRow row;
  final AbsenteeStatus status;
  final ColorScheme themed;

  @override
  Widget build(BuildContext context) {
    final critical = status == AbsenteeStatus.critical;
    final missed = row.sessionsHeld - row.sessionsAttended;
    return Column(
      children: [
        ListTile(
          dense: true,
          title: Text(row.studentId == row.fullName ? row.studentId : '${row.fullName} — ${row.studentId}'),
          subtitle: Text(
            'missed $missed of ${row.sessionsHeld} sessions · '
            '${row.attendancePct.toStringAsFixed(0)}%',
            style: const TextStyle(fontSize: 12),
          ),
          trailing: Chip(
            label: Text(
              critical ? 'CRITICAL' : 'WARNING',
              style: TextStyle(
                fontSize: 11,
                color: critical
                    ? themed.onErrorContainer
                    : themed.onTertiaryContainer,
              ),
            ),
            backgroundColor: critical
                ? themed.errorContainer
                : themed.tertiaryContainer,
          ),
        ),
        const Divider(height: 1),
      ],
    );
  }
}