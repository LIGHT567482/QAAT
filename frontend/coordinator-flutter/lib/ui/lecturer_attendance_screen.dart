import 'package:flutter/material.dart';

import '../net/lecturer_attendance_client.dart';
import '../net/net.dart';

/// LECTURER ATTENDANCE for the coordinator — the same two independent records the web
/// dashboards keep apart, plus the ability to RECORD a lecture at the door.
///
/// Two independent witnesses to the same lectures, NEVER merged (that is the finding):
///   • Coordinator record — what the lecturer started/ended in the session (contact hours)
///   • QA monitor record  — what a QA monitor saw on walking into the room
/// Where they disagree — a session the coordinator logged but a monitor found empty — is
/// exactly what QA exists to surface. So they stay on separate tabs.
/// A third path, the manual taught/not-taught record ("Record at door"), files a lecture
/// that has no timetable slot at all.
class LecturerAttendanceScreen extends StatefulWidget {
  const LecturerAttendanceScreen({
    super.key,
    required this.token,
    this.client,
    this.fingerprint,
  });

  final String token;
  final LecturerAttendanceClient? client;
  final String? fingerprint;

  @override
  State<LecturerAttendanceScreen> createState() => _LecturerAttendanceScreenState();
}

class _LecturerAttendanceScreenState extends State<LecturerAttendanceScreen> {
  late final LecturerAttendanceClient _client =
      widget.client ?? LecturerAttendanceClient(fingerprint: widget.fingerprint);

  bool _loading = true;
  String? _error;
  List<LecturerSummary> _summary = const [];
  List<AttendanceLog> _logs = const [];
  PatrolAttendance _patrol = const PatrolAttendance(summary: [], visits: []);

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  Future<void> _loadAll({String patrolFrom = '', String patrolTo = ''}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        _client.summary(widget.token),
        _client.logs(widget.token),
        _client.patrol(widget.token, from: patrolFrom, to: patrolTo),
      ]);
      if (!mounted) return;
      setState(() {
        _summary = results[0] as List<LecturerSummary>;
        _logs = results[1] as List<AttendanceLog>;
        _patrol = results[2] as PatrolAttendance;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = Net.friendly(e);
      });
    }
  }

  void _openManualSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => ManualAttendanceSheet(
        token: widget.token,
        client: _client,
        onRecorded: (msg) {
          _loadAll();
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Lecturer Attendance'),
          bottom: const TabBar(tabs: [
            Tab(text: 'Coordinator record'),
            Tab(text: 'QA monitor record'),
          ]),
          actions: [
            IconButton(
              tooltip: 'Refresh',
              onPressed: _loading ? null : _loadAll,
              icon: const Icon(Icons.refresh),
            ),
            IconButton(
              tooltip: 'Record a lecture at the door',
              onPressed: _openManualSheet,
              icon: const Icon(Icons.edit_note),
            ),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? _ErrorPanel(message: _error!, onRetry: _loadAll)
                : TabBarView(children: [
                    _CoordinatorRecord(
                      summary: _summary,
                      logs: _logs,
                      onRefresh: _loadAll,
                    ),
                    _MonitorRecord(
                      patrol: _patrol,
                      onReload: (from, to) => _loadAll(patrolFrom: from, patrolTo: to),
                    ),
                  ]),
      ),
    );
  }
}

/// Stand-in until Net.friendly() lands in a shared home — same wording the Android app
/// gives a coordinator, so a field failure is diagnosable rather than a stack trace.

class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 40),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.tonal(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}

/// ── TAB 1: COORDINATOR RECORD ─────────────────────────────────────────────────────
/// Proof-of-presence from the session itself — the lecturer's own start/end and the
/// contact hours between them. One row per lecturer; expand for every session.
class _CoordinatorRecord extends StatefulWidget {
  const _CoordinatorRecord({
    required this.summary,
    required this.logs,
    required this.onRefresh,
  });

  final List<LecturerSummary> summary;
  final List<AttendanceLog> logs;
  final VoidCallback onRefresh;

  @override
  State<_CoordinatorRecord> createState() => _CoordinatorRecordState();
}

class _CoordinatorRecordState extends State<_CoordinatorRecord> {
  final Set<String> _open = {};
  String _search = '';

  @override
  Widget build(BuildContext context) {
    final sq = _search.trim().toLowerCase();
    final visible = widget.summary.where((s) =>
        sq.isEmpty ||
        [s.lecturerName, s.department, s.email, s.staffId]
            .any((v) => v.toLowerCase().contains(sq)));

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        Text(
          'Proof-of-presence from the session itself — the lecturer\'s own start/end and '
          'the contact hours between them. One row per lecturer; expand for every session.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        TextField(
          onChanged: (v) => setState(() => _search = v),
          decoration: const InputDecoration(
            hintText: 'Search lecturer, department or email…',
            prefixIcon: Icon(Icons.search),
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 12),
        if (widget.summary.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text('No lecturer attendance recorded yet.'),
          )
        else ...[
          const _SummaryHeader(
            widths: [2.2, 1, 1, 1, 1],
            labels: ['Lecturer', 'Sessions', 'Total hrs', 'Avg hrs', 'Last'],
          ),
          for (final s in visible)
            _CoordinatorRow(
              s: s,
              expanded: _open.contains(s.lecturerId),
              onToggle: () => setState(() {
                _open.contains(s.lecturerId)
                    ? _open.remove(s.lecturerId)
                    : _open.add(s.lecturerId);
              }),
              logs: widget.logs.where((l) => l.lecturerId == s.lecturerId).toList(),
            ),
          if (visible.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('No lecturer matches the search.'),
            ),
        ],
      ],
    );
  }
}

class _SummaryHeader extends StatelessWidget {
  const _SummaryHeader({required this.widths, required this.labels});
  final List<double> widths;
  final List<String> labels;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < labels.length; i++)
          Expanded(
            flex: widths[i].round(),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(
                labels[i],
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
          ),
      ],
    );
  }
}

class _CoordinatorRow extends StatelessWidget {
  const _CoordinatorRow({
    required this.s,
    required this.expanded,
    required this.onToggle,
    required this.logs,
  });

  final LecturerSummary s;
  final bool expanded;
  final VoidCallback onToggle;
  final List<AttendanceLog> logs;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Column(
      children: [
        InkWell(
          onTap: onToggle,
          child: Row(
            children: [
              Expanded(
                flex: 22,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(s.lecturerName, style: t.textTheme.bodyMedium),
                    if (s.staffId.isNotEmpty)
                      Text(s.staffId,
                          style: t.textTheme.bodySmall
                              ?.copyWith(fontFamily: 'monospace', color: t.hintColor)),
                    if (s.department.isNotEmpty)
                      Text(s.department, style: t.textTheme.bodySmall),
                  ],
                ),
              ),
              Expanded(flex: 10, child: Text('${s.totalSessions}')),
              Expanded(
                  flex: 10,
                  child: Text(_one(s.totalContactHours))),
              Expanded(
                  flex: 10,
                  child: Text(_one(s.avgContactHours))),
              Expanded(
                  flex: 10,
                  child: Text(_fmtDate(s.lastSessionDate),
                      style: t.textTheme.bodySmall)),
              Icon(expanded ? Icons.expand_less : Icons.expand_more, size: 18),
            ],
          ),
        ),
        if (expanded)
          _CoordinatorLogs(logs: logs),
        Divider(height: 1, color: t.dividerColor),
      ],
    );
  }
}

class _CoordinatorLogs extends StatelessWidget {
  const _CoordinatorLogs({required this.logs});
  final List<AttendanceLog> logs;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    if (logs.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Text('No session logs.'),
      );
    }
    return Container(
      color: t.colorScheme.surfaceContainerLow,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _LogHeader(),
          for (final l in logs) _LogRow(l: l),
        ],
      ),
    );
  }
}

class _LogHeader extends StatelessWidget {
  const _LogHeader();

  @override
  Widget build(BuildContext context) {
    return const _SummaryHeader(
      widths: [1, 2, 1, 1, 1, 1],
      labels: ['Date', 'Unit', 'Class', 'Room', 'Stud.', 'Status'],
    );
  }
}

class _LogRow extends StatelessWidget {
  const _LogRow({required this.l});
  final AttendanceLog l;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: t.dividerColor)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(flex: 10, child: Text(_fmtDate(l.sessionDate))),
              Expanded(
                flex: 20,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l.unitName),
                    if (l.unitId.isNotEmpty)
                      Text(l.unitId,
                          style: t.textTheme.bodySmall
                              ?.copyWith(fontFamily: 'monospace', color: t.hintColor)),
                  ],
                ),
              ),
              Expanded(flex: 10, child: Text(l.classGroup.isEmpty ? '—' : l.classGroup)),
              Expanded(
                flex: 10,
                child: Text(l.room, style: t.textTheme.bodySmall),
              ),
              Expanded(flex: 10, child: Text('${l.studentsAttended}')),
              Expanded(
                  flex: 10,
                  child: Text(l.sessionStatus.replaceAll('_', ' '),
                      style: t.textTheme.bodySmall)),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            '${_fmtHm(l.gateOpenTime)} – ${l.gateCloseTime.isEmpty ? 'In progress' : _fmtHm(l.gateCloseTime)}'
            '   ·   ${l.contactHours > 0 ? '${l.contactHours.toStringAsFixed(2)} h' : '—'}'
            '${l.qaMonitor.isNotEmpty ? '   ·   QA: ${l.qaMonitor}${l.qaMonitorStaffId.isEmpty ? '' : ' ${l.qaMonitorStaffId}'}' : ''}'
            '${l.isCompensation ? '   ·   Compensation' : ''}',
            style: t.textTheme.bodySmall?.copyWith(color: t.hintColor),
          ),
        ],
      ),
    );
  }
}

/// ── TAB 2: QA MONITOR RECORD ──────────────────────────────────────────────────────
/// What a QA monitor observed on walking into the room — an independent check against
/// the coordinator's record.
class _MonitorRecord extends StatefulWidget {
  const _MonitorRecord({
    required this.patrol,
    required this.onReload,
  });

  final PatrolAttendance patrol;
  final Future<void> Function(String from, String to) onReload;

  @override
  State<_MonitorRecord> createState() => _MonitorRecordState();
}

class _MonitorRecordState extends State<_MonitorRecord> {
  DateTime? _from;
  DateTime? _to;
  String _search = '';
  final Set<String> _open = {};

  void _reload() {
    widget.onReload(
      _from == null ? '' : _dateOnly(_from!),
      _to == null ? '' : _dateOnly(_to!),
    );
  }

  @override
  Widget build(BuildContext context) {
    final summary = widget.patrol.summary;
    final sq = _search.trim().toLowerCase();
    final visible = summary.where((s) =>
        sq.isEmpty ||
        [s.lecturerName, s.lecturerId, s.department, s.school]
            .any((v) => v.toLowerCase().contains(sq)));

    final ta = summary.fold(0, (a, s) => a + s.taught);
    final tp = summary.fold(0, (a, s) => a + s.patrolled);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        Text(
          'What a QA monitor observed on walking into the room — an independent check '
          'against the coordinator\'s record. Use “Record at door” to file a lecture that '
          'is not on the timetable.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _DateFilterField(
                label: 'From',
                value: _from,
                onChanged: (d) {
                  setState(() => _from = d);
                  _reload();
                },
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _DateFilterField(
                label: 'To',
                value: _to,
                onChanged: (d) {
                  setState(() => _to = d);
                  _reload();
                },
              ),
            ),
            if (_from != null || _to != null)
              TextButton(
                onPressed: () {
                  setState(() {
                    _from = null;
                    _to = null;
                  });
                  _reload();
                },
                child: const Text('Clear'),
              ),
          ],
        ),
        TextField(
          onChanged: (v) => setState(() => _search = v),
          decoration: const InputDecoration(
            hintText: 'Search lecturer, staff ID, department…',
            prefixIcon: Icon(Icons.search),
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 8),
        if (summary.isEmpty)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFFFFFBEB),
              border: Border.all(color: const Color(0xFFFDE68A)),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Text(
              'No monitor visits recorded yet. Records appear here once a QA monitor '
              'submits their rounds from the phone app.',
            ),
          )
        else ...[
          Text(
            'Overall: $ta of $tp monitor visits found the lecturer teaching'
            '${tp > 0 ? ' (${(ta / tp * 100).round()}%)' : ''}.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 4),
          const _SummaryHeader(
            widths: [2, 1.4, 1.6, 1, 1, 1, 1],
            labels: ['Lecturer', 'Staff ID', 'Department', 'Monitored', 'Teaching', 'Missed', 'Rate'],
          ),
          for (final s in visible)
            _MonitorRow(
              s: s,
              expanded: _open.contains(s.lecturerId),
              onToggle: () => setState(() {
                _open.contains(s.lecturerId)
                    ? _open.remove(s.lecturerId)
                    : _open.add(s.lecturerId);
              }),
              visits: widget.patrol.visits.where((v) => v.lecturerId == s.lecturerId).toList(),
            ),
        ],
      ],
    );
  }
}

class _MonitorRow extends StatelessWidget {
  const _MonitorRow({
    required this.s,
    required this.expanded,
    required this.onToggle,
    required this.visits,
  });

  final PatrolSummary s;
  final bool expanded;
  final VoidCallback onToggle;
  final List<PatrolVisit> visits;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final good = s.rate >= 75;
    return Column(
      children: [
        InkWell(
          onTap: onToggle,
          child: Row(
            children: [
              Expanded(
                  flex: 20,
                  child:
                      Text(s.lecturerName.isEmpty ? s.lecturerId : s.lecturerName)),
              Expanded(
                flex: 14,
                child: Text(s.lecturerId,
                    style: t.textTheme.bodySmall?.copyWith(fontFamily: 'monospace')),
              ),
              Expanded(flex: 16, child: Text(s.department, style: t.textTheme.bodySmall)),
              Expanded(flex: 10, child: Text('${s.patrolled}')),
              Expanded(
                  flex: 10,
                  child: Text('${s.taught}',
                      style: TextStyle(
                          color: Colors.green.shade700, fontWeight: FontWeight.w600))),
              Expanded(
                  flex: 10,
                  child: Text('${s.missed}',
                      style: s.missed > 0
                          ? TextStyle(
                              color: Colors.red.shade800, fontWeight: FontWeight.w700)
                          : null)),
              Expanded(
                flex: 10,
                child: Text(
                  '${s.rate.toStringAsFixed(0)}%',
                  style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: good ? Colors.green.shade700 : Colors.red.shade800),
                ),
              ),
              Icon(expanded ? Icons.expand_less : Icons.expand_more, size: 18),
            ],
          ),
        ),
        if (expanded) _VisitList(visits: visits),
        Divider(height: 1, color: t.dividerColor),
      ],
    );
  }
}

class _VisitList extends StatelessWidget {
  const _VisitList({required this.visits});
  final List<PatrolVisit> visits;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      color: t.colorScheme.surfaceContainerLow,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Column(
        children: [
          const _SummaryHeader(
            widths: [1.4, 1, 2, 1, 1.4, 1, 2],
            labels: ['Date', 'Time', 'Unit', 'Class', 'Room', 'Verdict', 'Monitor'],
          ),
          if (visits.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('No visits in this date range.'),
            ),
          for (final v in visits) _VisitRow(v: v),
        ],
      ),
    );
  }
}

class _VisitRow extends StatelessWidget {
  const _VisitRow({required this.v});
  final PatrolVisit v;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(border: Border(top: BorderSide(color: t.dividerColor))),
      child: Row(
        children: [
          Expanded(flex: 14, child: Text(_fmtDate(v.sessionDate))),
          Expanded(flex: 10, child: Text(v.scheduledTime)),
          Expanded(
            flex: 20,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(v.unitName.isEmpty ? v.unitId : v.unitName),
                if (v.unitId.isNotEmpty && v.unitId != v.unitName)
                  Text(v.unitId,
                      style: t.textTheme.bodySmall
                          ?.copyWith(fontFamily: 'monospace', color: t.hintColor)),
              ],
            ),
          ),
          Expanded(flex: 10, child: Text(v.classGroup.isEmpty ? '—' : v.classGroup)),
          Expanded(flex: 14, child: Text(v.room, style: t.textTheme.bodySmall)),
          Expanded(
            flex: 10,
            child: _VerdictChip(taught: v.taught),
          ),
          Expanded(
            flex: 20,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(v.qaMonitor.isEmpty ? v.patrollerName : v.qaMonitor),
                if ((v.qaMonitorStaffId.isEmpty ? v.patrollerStaffId : v.qaMonitorStaffId)
                    .isNotEmpty)
                  Text(
                    (v.qaMonitorStaffId.isEmpty ? v.patrollerStaffId : v.qaMonitorStaffId),
                    style: t.textTheme.bodySmall?.copyWith(color: t.hintColor),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _VerdictChip extends StatelessWidget {
  const _VerdictChip({required this.taught});
  final bool taught;

  @override
  Widget build(BuildContext context) {
    final colour = taught ? Colors.green.shade700 : Colors.red.shade800;
    final bg = taught ? Colors.green.shade50 : Colors.red.shade50;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        taught ? 'TEACHING' : 'NOT TEACHING',
        style: TextStyle(
            color: colour, fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: .3),
      ),
    );
  }
}

/// A compact date filter whose value sits in the expanded row until picked.
class _DateFilterField extends StatelessWidget {
  const _DateFilterField({required this.label, required this.value, required this.onChanged});
  final String label;
  final DateTime? value;
  final ValueChanged<DateTime?> onChanged;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: value ?? DateTime.now(),
          firstDate: DateTime(2020),
          lastDate: DateTime.now().add(const Duration(days: 1)),
        );
        onChanged(picked);
      },
      child: Text(value == null ? label : _fmtDate(_dateOnly(value!))),
    );
  }
}

/// ── MANUAL RECORD: THE LECTURE THE TIMETABLE DOES NOT KNOW ABOUT ──────────────────
/// Every field is pick-or-type. A list alone would refuse to record the unit not yet in
/// the curriculum or the lecturer hired last week; free text alone would produce a drift
/// of near-miss spellings no report can group. Picking a unit fills in its class/group
/// and college; picking a lecturer brings their department and college with them.
class ManualAttendanceSheet extends StatefulWidget {
  const ManualAttendanceSheet({
    super.key,
    required this.token,
    required this.client,
    required this.onRecorded,
  });

  final String token;
  final LecturerAttendanceClient client;

  /// Called with a confirmation sentence after a successful record.
  final ValueChanged<String> onRecorded;

  @override
  State<ManualAttendanceSheet> createState() => _ManualAttendanceSheetState();
}

class _ManualAttendanceSheetState extends State<ManualAttendanceSheet> {
  PatrolReference? _ref;
  String? _error;
  bool _busy = false;

  final _roomId = ValueNotifier('');
  final _roomText = TextEditingController();
  final _unitId = ValueNotifier('');
  final _unitText = TextEditingController();
  final _classGroup = TextEditingController();
  final _lecturerId = ValueNotifier('');
  final _lecturerText = TextEditingController();
  final _students = TextEditingController();
  final _schoolId = ValueNotifier('');
  final _school = TextEditingController();
  final _departmentId = ValueNotifier('');
  final _department = TextEditingController();
  final _remarks = TextEditingController();
  var _isComp = false;
  final _compDate = TextEditingController();
  final _compTime = TextEditingController();
  final _begins = TextEditingController(text: _nowHHMM());
  final _ends = TextEditingController();
  final List<ExtraUnit> _extras = [];

  @override
  void initState() {
    super.initState();
    _loadReference();
  }

  @override
  void dispose() {
    for (final c in [
      _roomText, _unitText, _classGroup, _lecturerText, _students,
      _school, _department, _remarks, _compDate, _compTime, _begins, _ends,
    ]) {
      c.dispose();
    }
    for (final n in [_roomId, _unitId, _lecturerId, _schoolId, _departmentId]) {
      n.dispose();
    }
    super.dispose();
  }

  Future<void> _loadReference() async {
    final r = await widget.client.reference(widget.token);
    if (!mounted) return;
    setState(() => _ref = r);
  }

  /// Choose a unit: fills its class/group and college, but only into blanks — what the
  /// coordinator typed or corrected wins.
  void _chooseUnit(RefItem item) {
    setState(() {
      _unitId.value = item.id;
      _unitText.text = item.label;
      final defs = _ref?.unitDefaults[item.id];
      if (defs != null) {
        if (_classGroup.text.isEmpty) _classGroup.text = defs.$1;
        if (_school.text.isEmpty) _school.text = defs.$2;
      }
      final dept = _ref?.unitDepartments[item.id] ?? '';
      if (dept.isNotEmpty && _department.text.isEmpty) {
        _department.text = dept;
        if (_school.text.isEmpty) {
          _school.text = _ref!.departments
              .firstWhere((d) => d.label.toLowerCase() == dept.toLowerCase(),
                  orElse: () => const RefItem('', ''))
              .extra;
        }
      }
      _departmentId.value = _knownId(_ref?.departments ?? const [], _department.text);
      _schoolId.value = _knownId(_schoolOptions, _school.text);
    });
  }

  void _chooseLecturer(RefItem item) {
    setState(() {
      _lecturerId.value = item.id;
      _lecturerText.text = item.label;
      if (item.extra.isNotEmpty && _department.text.isEmpty) {
        _department.text = item.extra;
      }
      if (_school.text.isEmpty) {
        _school.text = _ref?.lecturerSchools[item.id] ?? '';
        if (_school.text.isEmpty) {
          _school.text = _ref!.departments
              .firstWhere((d) => d.label.toLowerCase() == _department.text.toLowerCase(),
                  orElse: () => const RefItem('', ''))
              .extra;
        }
      }
      _departmentId.value = _knownId(_ref?.departments ?? const [], _department.text);
      _schoolId.value = _knownId(_schoolOptions, _school.text);
    });
  }

  List<RefItem> get _schoolOptions =>
      (_ref?.schools ?? []).map((s) => RefItem(s, s)).toList();

  String _knownId(List<RefItem> options, String value) {
    final v = value.trim();
    if (v.isEmpty) return '';
    for (final o in options) {
      if (o.label.toLowerCase() == v.toLowerCase()) return o.label;
    }
    return '';
  }

  Future<void> _submit(bool isTeaching) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final entry = ManualEntry(
      roomId: _roomId.value,
      room: _roomText.text.trim(),
      unitId: _unitId.value,
      unitName: _unitText.text.trim(),
      lecturerStaffId: _lecturerId.value,
      lecturerName: _lecturerText.text.trim(),
      classGroup: _classGroup.text.trim(),
      school: _school.text.trim(),
      department: _department.text.trim(),
      studentsCounted: int.tryParse(_students.text) ?? 0,
      sessionDate: _todayOnly(),
      timeOfDay: _begins.text.trim(),
      endTime: _ends.text.trim(),
      taught: isTeaching,
      remarks: _remarks.text.trim(),
      isCompensation: _isComp,
      compensationForAt: _isComp
          ? '${_compDate.text.trim()} ${_compTime.text.trim()}'.trim()
          : '',
      alsoUnits: List.of(_extras),
    );
    final msg = await widget.client.manual(widget.token, entry);
    if (!mounted) return;
    setState(() => _busy = false);
    if (msg == null) {
      final which = _unitText.text.trim().isNotEmpty ? _unitText.text.trim() : entry.unitId;
      Navigator.of(context).pop();
      widget.onRecorded('Recorded — $which');
    } else {
      setState(() => _error = msg);
    }
  }

  bool get _blocked {
    final badSpan = _ends.text.isNotEmpty && !endsAfter(_begins.text, _ends.text);
    final noComp = _isComp &&
        (_compDate.text.isEmpty || _compTime.text.isEmpty || !isHHMM(_compTime.text));
    return badSpan || noComp;
  }

  @override
  Widget build(BuildContext context) {
    final ref = _ref;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.9,
      maxChildSize: 0.95,
      builder: (context, scrollController) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          child: Column(
            children: [
              Text('Attendance recorded manually',
                  style: Theme.of(context).textTheme.titleMedium),
              Text(
                'For a lecture that is happening but is not on the timetable. Pick from '
                'the lists where you can, type where you cannot.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              if (_error != null)
                Text(_error!,
                    style: TextStyle(color: Theme.of(context).colorScheme.error)),
              Expanded(
                child: ListView(
                  controller: scrollController,
                  children: [
                    if (ref == null)
                      const Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    else ...[
                      _PickOrTypeField(
                        label: 'Room',
                        controller: _roomText,
                        selectedId: _roomId,
                        options: ref.rooms,
                        onPick: (item) {
                          _roomId.value = item.id;
                          _roomText.text = item.label;
                        },
                        onType: () => _roomId.value = '',
                      ),
                      _PickOrTypeField(
                        label: 'Course unit',
                        controller: _unitText,
                        selectedId: _unitId,
                        options: ref.units,
                        onPick: _chooseUnit,
                        onType: () => _unitId.value = '',
                      ),
                      _PlainField(label: 'Class / Group  (e.g. 2:1)', controller: _classGroup),
                      _PickOrTypeField(
                        label: 'Lecturer',
                        controller: _lecturerText,
                        selectedId: _lecturerId,
                        options: ref.lecturers,
                        onPick: _chooseLecturer,
                        onType: () => _lecturerId.value = '',
                      ),
                      _PlainField(
                        label: 'Number of students in the room',
                        controller: _students,
                        keyboardType: TextInputType.number,
                        maxLength: 4,
                      ),
                      _PickOrTypeField(
                        label: 'School / College',
                        controller: _school,
                        selectedId: _schoolId,
                        options: _schoolOptions,
                        onPick: (item) {
                          _school.text = item.label;
                          _schoolId.value = item.label;
                        },
                        onType: () => _schoolId.value = '',
                      ),
                      _PickOrTypeField(
                        label: 'Department',
                        controller: _department,
                        selectedId: _departmentId,
                        options: ref.departments,
                        onPick: (item) {
                          _department.text = item.label;
                          _departmentId.value = item.label;
                          if (_school.text.isEmpty) {
                            _school.text = item.extra;
                            _schoolId.value = _knownId(_schoolOptions, item.extra);
                          }
                        },
                        onType: () => _departmentId.value = '',
                      ),
                      const SizedBox(height: 12),
                      Text('Lecture time',
                          style: Theme.of(context).textTheme.labelLarge),
                      Row(
                        children: [
                          Expanded(
                              child: _TimeField(
                                  label: 'Begins', controller: _begins)),
                          const SizedBox(width: 8),
                          Expanded(
                              child: _TimeField(label: 'Ends', controller: _ends)),
                        ],
                      ),
                      if (_ends.text.isNotEmpty && !endsAfter(_begins.text, _ends.text))
                        Text('The end has to be after the start.',
                            style: TextStyle(color: Theme.of(context).colorScheme.error)),
                      Row(
                        children: [
                          Checkbox(
                              value: _isComp,
                              onChanged: (v) => setState(() => _isComp = v ?? false)),
                          const Expanded(child: Text('This is a compensation lecture')),
                        ],
                      ),
                      if (_isComp) ...[
                        Text('Which lecture is this making good?',
                            style: Theme.of(context).textTheme.labelLarge),
                        Row(
                          children: [
                            Expanded(
                                child: _DateField(
                                    label: 'Its date', controller: _compDate)),
                            const SizedBox(width: 8),
                            Expanded(
                                child: _TimeField(
                                    label: 'It began at', controller: _compTime)),
                          ],
                        ),
                        if (_compDate.text.isEmpty || _compTime.text.isEmpty)
                          Text('Both are needed — a compensation that cannot be matched to '
                              'a missed lecture cannot be counted as making it good.',
                              style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                  fontSize: 12)),
                      ],
                      _PlainField(
                          label: 'Remarks (optional)', controller: _remarks,
                          maxLines: 2),
                      Text('Is the lecturer teaching?',
                          style: Theme.of(context).textTheme.labelLarge),
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton(
                              onPressed: _busy || _blocked ? null : () => _submit(true),
                              style: FilledButton.styleFrom(
                                  minimumSize: const Size.fromHeight(52)),
                              child: const Text('✓  Teaching'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: FilledButton(
                              onPressed: _busy || _blocked ? null : () => _submit(false),
                              style: FilledButton.styleFrom(
                                  minimumSize: const Size.fromHeight(52),
                                  backgroundColor:
                                      Theme.of(context).colorScheme.error),
                              child: const Text('✗  Not teaching'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// One field that is a dropdown AND a text box: choosing from the list writes the text,
/// editing the text clears the choice, so what's on screen is exactly what will be sent.
class _PickOrTypeField extends StatefulWidget {
  const _PickOrTypeField({
    required this.label,
    required this.controller,
    required this.selectedId,
    required this.options,
    required this.onPick,
    required this.onType,
  });

  final String label;
  final TextEditingController controller;
  final ValueNotifier<String> selectedId;
  final List<RefItem> options;
  final ValueChanged<RefItem> onPick;
  final VoidCallback onType;

  @override
  State<_PickOrTypeField> createState() => _PickOrTypeFieldState();
}

class _PickOrTypeFieldState extends State<_PickOrTypeField> {
  late List<RefItem> _matches;
  bool _showMatches = false;

  @override
  void initState() {
    super.initState();
    _matches = widget.options.take(60).toList();
    widget.selectedId.addListener(_refresh);
  }

  @override
  void dispose() {
    widget.selectedId.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  void _onChanged(String v) {
    widget.onType();
    final q = v.trim().toLowerCase();
    setState(() {
      _showMatches = true;
      _matches = q.isEmpty
          ? widget.options.take(60).toList()
          : widget.options
              .where((o) =>
                  o.label.toLowerCase().contains(q) || o.id.toLowerCase().contains(q))
              .take(60)
              .toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: widget.controller,
            onChanged: _onChanged,
            onTap: () => setState(() => _showMatches = true),
            decoration: InputDecoration(labelText: widget.label, border: const OutlineInputBorder()),
          ),
          if (_showMatches && _matches.isNotEmpty)
            Container(
              decoration: BoxDecoration(
                border: Border.all(color: t.dividerColor),
                borderRadius: BorderRadius.circular(6),
              ),
              constraints: const BoxConstraints(maxHeight: 160),
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final m in _matches)
                    ListTile(
                      dense: true,
                      title: Text(m.label, style: t.textTheme.bodyMedium),
                      subtitle: (m.id.isNotEmpty || m.extra.isNotEmpty)
                          ? Text(
                              [m.id, m.extra].where((s) => s.isNotEmpty).join(' · '),
                              style: t.textTheme.bodySmall)
                          : null,
                      onTap: () {
                        widget.onPick(m);
                        setState(() => _showMatches = false);
                        FocusScope.of(context).unfocus();
                      },
                    ),
                ],
              ),
            )
          else if (_showMatches)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                widget.controller.text.trim().isEmpty
                    ? 'Choose one, or type it'
                    : 'Nothing matches — what you typed will be used',
                style: t.textTheme.bodySmall?.copyWith(color: t.hintColor),
              ),
            ),
        ],
      ),
    );
  }
}

class _PlainField extends StatelessWidget {
  const _PlainField({
    required this.label,
    required this.controller,
    this.keyboardType,
    this.maxLength,
    this.maxLines = 1,
  });

  final String label;
  final TextEditingController controller;
  final TextInputType? keyboardType;
  final int? maxLength;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: controller,
        keyboardType: keyboardType,
        maxLength: maxLength,
        maxLines: maxLines,
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
      ),
    );
  }
}

/// A time field that only ever holds HH:MM. Typed digits are shaped as they are entered,
/// so the form cannot carry prose where the record needs a clock time.
class _TimeField extends StatelessWidget {
  const _TimeField({required this.label, required this.controller});
  final String label;
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(
        labelText: label,
        hintText: 'HH:MM',
        border: const OutlineInputBorder(),
        errorText: controller.text.isNotEmpty && !isHHMM(controller.text)
            ? 'HH:MM'
            : null,
      ),
      onChanged: (_) => controller.text = shapeHHMM(controller.text),
    );
  }
}

/// A date field that only ever holds YYYY-MM-DD.
class _DateField extends StatelessWidget {
  const _DateField({required this.label, required this.controller});
  final String label;
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(
        labelText: label,
        hintText: 'YYYY-MM-DD',
        border: const OutlineInputBorder(),
      ),
      onChanged: (_) => controller.text = shapeDate(controller.text),
    );
  }
}

// ── Formatting / validation helpers ────────────────────────────────────────────────
String _fmtDate(String iso) {
  if (iso.isEmpty) return '—';
  final p = DateTime.tryParse(iso);
  if (p == null) return iso;
  return '${p.year}-${two(p.month)}-${two(p.day)}';
}

String _fmtHm(String rfc3339) {
  if (rfc3339.isEmpty) return '—';
  final p = DateTime.tryParse(rfc3339);
  if (p == null) return rfc3339;
  return '${two(p.hour)}:${two(p.minute)}';
}

String _one(double d) => d.toStringAsFixed(1);

String two(int n) => n.toString().padLeft(2, '0');

String _todayOnly() {
  final n = DateTime.now();
  return '${n.year}-${two(n.month)}-${two(n.day)}';
}

String _dateOnly(DateTime d) => '${d.year}-${two(d.month)}-${two(d.day)}';

String _nowHHMM() {
  final n = DateTime.now();
  return '${two(n.hour)}:${two(n.minute)}';
}

/// Shape raw digits into HH:MM as they are entered.
String shapeHHMM(String raw) {
  final d = raw.replaceAll(RegExp(r'\D'), '');
  final digits = d.length > 4 ? d.substring(0, 4) : d;
  if (digits.length <= 2) return digits;
  return '${digits.substring(0, 2)}:${digits.substring(2)}';
}

/// Shape raw digits into YYYY-MM-DD as they are entered.
String shapeDate(String raw) {
  final d = raw.replaceAll(RegExp(r'\D'), '');
  final digits = d.length > 8 ? d.substring(0, 8) : d;
  if (digits.length <= 4) return digits;
  if (digits.length <= 6) {
    return '${digits.substring(0, 4)}-${digits.substring(4)}';
  }
  return '${digits.substring(0, 4)}-${digits.substring(4, 6)}-${digits.substring(6)}';
}

bool isHHMM(String s) =>
    s.length == 5 &&
    s[2] == ':' &&
    int.tryParse(s.substring(0, 2)) != null &&
    int.parse(s.substring(0, 2)) >= 0 &&
    int.parse(s.substring(0, 2)) <= 23 &&
    int.parse(s.substring(3, 5)) >= 0 &&
    int.parse(s.substring(3, 5)) <= 59;

int _hhmmToMinutes(String s) =>
    isHHMM(s) ? int.parse(s.substring(0, 2)) * 60 + int.parse(s.substring(3, 5)) : -1;

/// A class that "ends" before it began is a typo, and storing it would put a negative
/// hour into contact-time reporting.
bool endsAfter(String begins, String ends) {
  final b = _hhmmToMinutes(begins);
  final e = _hhmmToMinutes(ends);
  return b >= 0 && e >= 0 && e > b;
}