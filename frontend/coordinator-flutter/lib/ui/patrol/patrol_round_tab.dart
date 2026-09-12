import 'dart:math';

import 'package:flutter/material.dart';

import '../../patrol/fingerprint.dart';
import '../../patrol/patrol_client.dart';
import '../../patrol/patrol_models.dart';
import '../../patrol/patrol_store.dart';
import 'manual_attendance_sheet.dart';
import 'sync_pending.dart';

/// Today on THIS phone's calendar, YYYY-MM-DD — the date a monitor observation is
/// filed under even when the server has not caught up.
String todayDate() {
  final n = DateTime.now();
  return '${n.year.toString().padLeft(4, '0')}-'
      '${n.month.toString().padLeft(2, '0')}-'
      '${n.day.toString().padLeft(2, '0')}';
}

/// THE ROOM ROUND — a faithful port of the native `PatrolRoundTab`.
///
/// SEARCH FIRST. The round used to open on every timetabled session with a pair of
/// tick buttons — a screen that invites ticking without visiting. A monitor record is
/// weighed against the coordinator's own precisely because it comes from someone who
/// was there, so the monitor now looks a lecturer or unit up before anything appears.
class PatrolRoundTab extends StatefulWidget {
  const PatrolRoundTab({
    super.key,
    required this.token,
    required this.reloadKey,
    this.name = '',
    this.staffId = '',
  });

  final String token;
  final int reloadKey;
  final String name;
  final String staffId;

  @override
  State<PatrolRoundTab> createState() => _PatrolRoundTabState();
}

class _PatrolRoundTabState extends State<PatrolRoundTab> {
  final PatrolClient _client = PatrolClient();

  String _mode = 'lecturer'; // "lecturer" | "unit"
  String _query = '';
  List<PatrolSlot>? _results; // null = nothing searched yet
  bool _searching = false;
  String? _note;
  int _pending = 0;
  final List<PatrolLog> _todayLogs = [];

  @override
  void initState() {
    super.initState();
    _refreshCache();
  }

  @override
  void didUpdateWidget(PatrolRoundTab old) {
    super.didUpdateWidget(old);
    if (old.reloadKey != widget.reloadKey) _refreshCache();
  }

  Future<void> _refreshCache() async {
    final token = widget.token;
    if (token.isNotEmpty) {
      try {
        final fresh = await _client.manifest(token, await DeviceFingerprint.get());
        await patrolStore.replacePatrolSlots(fresh);
      } on PatrolDeviceRejected catch (e) {
        if (mounted) setState(() => _note = e.message);
      } on Object {
        // Offline — the cached week stays.
      }
    }
    // BOTH queues, from this tab. See sync_pending.dart for why neither may be
    // stranded behind the screen that filled it.
    final n1 = await syncPending(token);
    final n2 = await syncPendingOffice(token);
    await _reloadPending();
    if (!mounted) return;
    setState(() {
      if (n1 != null) _note ??= n1;
      if (n2 != null) _note ??= n2;
    });
  }

  /// Re-read today's logs (the done-map) + combined pending count from the store.
  Future<void> _reloadPending() async {
    final logs = await patrolStore.patrolLogsForDay(todayDate());
    final p = await pendingTotal();
    if (!mounted) return;
    setState(() {
      _todayLogs
        ..clear()
        ..addAll(logs);
      _pending = p;
    });
  }

  Future<void> _runSearch() async {
    final q = _query.trim();
    if (q.isEmpty) {
      setState(() => _results = null);
      return;
    }
    setState(() {
      _searching = true;
      _note = null;
    });
    final token = widget.token;
    List<PatrolSlot>? online;
    if (token.isNotEmpty) {
      try {
        online =
            await _client.search(token, await DeviceFingerprint.get(), _mode, q);
      } on PatrolDeviceRejected catch (e) {
        if (mounted) setState(() => _note = e.message);
      } on Object {
        online = null;
      }
    }

    final results = online ?? await _offlineSearch(q);
    if (!mounted) return;
    setState(() {
      _results = results;
      _searching = false;
      if (online == null) _note ??= 'Offline — searching today\'s cached timetable.';
    });
  }

  /// The cached day, narrowed to today, with the SAME matching rule as the server —
  /// prefix, case-insensitive, staff id/name (lecturer) or unit id/name — so the
  /// monitor does not get a different answer depending on the signal.
  Future<List<PatrolSlot>> _offlineSearch(String q) async {
    final needle = q.toLowerCase();
    final dow = DateTime.now().weekday; // 1..7 — matches the server's day_of_week
    final cached = await patrolStore.patrolSlotsForDay(dow);
    final hits = cached.where((s) {
      if (_mode == 'lecturer') {
        return s.lecturerStaffId.toLowerCase().startsWith(needle) ||
            s.lecturerName.toLowerCase().startsWith(needle);
      }
      return s.unitId.toLowerCase().startsWith(needle) ||
          s.unitName.toLowerCase().startsWith(needle);
    }).toList()..sort((a, b) => a.startTime.compareTo(b.startTime));
    return hits;
  }

  Future<void> _tick(
      PatrolSlot s, bool taught, FoundElsewhere? found, Compensation? comp) async {
    final log = PatrolLog(
      id: _uuid(),
      unitId: s.unitId,
      unitName: s.unitName,
      courseCode: s.courseCode,
      lecturerId: s.lecturerStaffId,
      lecturerName: s.lecturerName,
      room: s.room,
      sessionDate: todayDate(),
      scheduledTime: s.startTime,
      taught: taught,
      takenAt: DateTime.now().toUtc().toIso8601String(),
      offeringId: s.offeringId,
      foundVenue: found?.venue ?? '',
      foundStartTime: found?.time ?? '',
      foundDate: found?.date ?? '',
      venueChanged: found != null,
      remarks: found?.remarks ?? '',
      isCompensation: comp != null,
      compensationFor: comp?.forDate ?? '',
    );
    await patrolStore.putPatrolLog(log);
    await _reloadPending();
    final n = await syncPending(widget.token);
    await _reloadPending();
    if (!mounted) return;
    setState(() {
      if (n != null) _note = n;
    });
  }

  String _uuid() {
    final r = Random.secure();
    final b = List<int>.generate(16, (_) => r.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    final hex = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
        '${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  String _slotKey(String unitId, String time, String offeringId) =>
      PatrolSlot.key(unitId, time, offeringId);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final done = {
      for (final l in _todayLogs) _slotKey(l.unitId, l.scheduledTime, l.offeringId): l
    };
    final onSurface = theme.colorScheme.onSurfaceVariant;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Monitor — ${widget.name.isNotEmpty ? widget.name : 'QA'}',
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.bold)),
        Text(
          'Staff ID: ${widget.staffId.isNotEmpty ? widget.staffId : '—'}'
          '${_pending > 0 ? '   ·   $_pending pending sync' : '   ·   all synced'}',
          style: theme.textTheme.bodySmall?.copyWith(color: onSurface),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Text(
            'Search the lecturer or the unit you are standing in front of, then '
            'record whether they are teaching. Works offline.',
            style: theme.textTheme.bodySmall?.copyWith(color: onSurface),
          ),
        ),
        Row(children: [
          _SearchChip('By lecturer ID', _mode == 'lecturer', () {
            setState(() {
              _mode = 'lecturer';
              _results = null;
            });
          }),
          const SizedBox(width: 8),
          _SearchChip('By unit code', _mode == 'unit', () {
            setState(() {
              _mode = 'unit';
              _results = null;
            });
          }),
        ]),
        const SizedBox(height: 8),
        TextField(
          onChanged: (v) => setState(() => _query = v),
          onSubmitted: (_) => _runSearch(),
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            labelText: _mode == 'lecturer'
                ? 'Lecturer staff ID or name'
                : 'Unit code or name',
            hintText: _mode == 'lecturer' ? 'e.g. KIU/044' : 'e.g. CS201',
            border: const OutlineInputBorder(),
            suffixIcon: TextButton(
              onPressed: _query.trim().isNotEmpty && !_searching ? _runSearch : null,
              child: Text(_searching ? '…' : 'Search'),
            ),
          ),
        ),
        if (_note != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: theme.colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(_note!,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onErrorContainer)),
            ),
          ),
        const SizedBox(height: 12),
        Expanded(child: _buildResults(theme, done)),
      ],
    );
  }

  Widget _buildResults(ThemeData theme, Map<String, PatrolLog> done) {
    final hits = _results;
    final Widget body;
    if (_searching) {
      body = const Center(
          child: Padding(
        padding: EdgeInsets.only(top: 40),
        child: CircularProgressIndicator(),
      ));
    } else if (hits == null) {
      body = Padding(
        padding: const EdgeInsets.only(top: 20),
        child: Text(
          'No lecturer is shown until you search. Enter the staff ID or the unit '
          'code for the room you are at.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      );
    } else if (hits.isEmpty) {
      body = Padding(
        padding: const EdgeInsets.only(top: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Nothing timetabled today matches "${_query.trim()}". Check the ID, '
              'or try searching the other way.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            Text(
              'If the lecture is happening anyway and simply is not on the timetable, '
              'record it by hand — it will be filed as a manual entry, not as a '
              'timetabled one.',
              style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: () => _openManual(),
              child: const Text('Record this lecture manually'),
            ),
          ],
        ),
      );
    } else {
      body = ListView.separated(
        itemCount: hits.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (_, i) => PatrolResultCard(
          slot: hits[i],
          recorded: done[_slotKey(hits[i].unitId, hits[i].startTime, hits[i].offeringId)],
          onOpen: () => _openConfirm(hits[i]),
        ),
      );
    }
    return body;
  }

  Future<void> _openConfirm(PatrolSlot slot) async {
    final decision = await showModalBottomSheet<({bool taught, FoundElsewhere? found, Compensation? comp})>(
      context: context,
      isScrollControlled: true,
      builder: (_) => PatrolConfirmSheet(slot: slot),
    );
    if (decision == null) return;
    await _tick(slot, decision.taught, decision.found, decision.comp);
  }

  Future<void> _openManual() async {
    final recorded = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) => ManualAttendanceSheet(
          token: widget.token, title: 'Attendance taken manually'),
    );
    if (recorded != null && mounted) {
      setState(() {
        _results = null;
        _note = recorded;
      });
    }
  }
}

// The sub-screens read nothing global — the round app passes identity in through
// the constructor fields above, so tests can build a round with any name.

class _SearchChip extends StatelessWidget {
  const _SearchChip(this.label, this.selected, this.onTap);
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return FilterChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
    );
  }
}

/// What the monitor recorded about a lecture making good an earlier one.
class Compensation {
  const Compensation(this.forDate);
  final String forDate;
}

/// What the monitor found, when it was not where the timetable said.
class FoundElsewhere {
  const FoundElsewhere(this.venue, this.time, this.date, this.remarks);
  final String venue;
  final String time;
  final String date;
  final String remarks;
}

/// One search hit. Tapping it opens the confirm sheet — the card itself cannot
/// tick, so a verdict is always two deliberate actions rather than one thumb on a
/// scrolling list.
class PatrolResultCard extends StatelessWidget {
  const PatrolResultCard({
    super.key,
    required this.slot,
    required this.recorded,
    required this.onOpen,
  });

  final PatrolSlot slot;
  final PatrolLog? recorded;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurfaceVariant;
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Text(slot.startTime,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontFamily: 'monospace')),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${slot.unitName.isNotEmpty ? slot.unitName : slot.unitId}'
                    '${slot.courseCode.isNotEmpty ? '  (${slot.courseCode})' : ''}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ]),
              Text('Lecturer: ${slot.lecturerName.isNotEmpty ? slot.lecturerName : slot.lecturerStaffId.isNotEmpty ? slot.lecturerStaffId : '—'}',
                  style: theme.textTheme.bodySmall?.copyWith(color: onSurface)),
              Text('Room: ${slot.room.isNotEmpty ? slot.room : '—'}',
                  style: theme.textTheme.bodySmall?.copyWith(color: onSurface)),
              if (slot.cohort.isNotEmpty)
                Text(slot.cohort,
                    style: theme.textTheme.bodySmall?.copyWith(color: onSurface)),
              if (slot.alsoHere.isNotEmpty)
                Text('Also in this room now: ${slot.alsoHere}',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.primary)),
              if (recorded != null) ...[
                const SizedBox(height: 6),
                Text(
                  '${recorded!.taught ? '✓ Already marked TAUGHT' : '✗ Already marked NOT TAUGHT'}'
                  '${!recorded!.synced ? ' · queued' : ''}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: recorded!.taught
                        ? theme.colorScheme.primary
                        : theme.colorScheme.error,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The verdict screen: is this lecturer teaching, yes or no. A bottom sheet mirror
/// of the native `PatrolConfirmSheet`.
class PatrolConfirmSheet extends StatefulWidget {
  const PatrolConfirmSheet({super.key, required this.slot});

  final PatrolSlot slot;

  @override
  State<PatrolConfirmSheet> createState() => _PatrolConfirmSheetState();
}

class _PatrolConfirmSheetState extends State<PatrolConfirmSheet> {
  bool _moved = false;
  bool _isComp = false;
  String _compFor = '';
  late String _venue;
  late String _time;
  late String _date;
  String _remarks = '';

  @override
  void initState() {
    super.initState();
    _venue = widget.slot.room;
    _time = widget.slot.startTime;
    _date = todayDate();
  }

  /// Only counts as a change if something actually differs — ticking the box and
  /// editing nothing must not raise an alert telling a lecturer their lecture moved
  /// to where it was.
  FoundElsewhere? _found() {
    if (!_moved) return null;
    final changed = _venue.trim() != widget.slot.room.trim() ||
        _time.trim() != widget.slot.startTime.trim() ||
        _date.trim() != todayDate();
    if (!changed && _remarks.trim().isEmpty) return null;
    return FoundElsewhere(_venue.trim(), _time.trim(), _date.trim(), _remarks.trim());
  }

  /// The date is optional: a monitor told "this is a compensation" but not which
  /// lecture it makes good is still recording something true.
  Compensation? _compensation() => _isComp ? Compensation(_compFor.trim()) : null;

  void _decide(bool taught) {
    Navigator.of(context).pop((taught: taught, found: _found(), comp: _compensation()));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = widget.slot;
    final onSurface = theme.colorScheme.onSurfaceVariant;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(s.unitName.isNotEmpty ? s.unitName : s.unitId,
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            if (s.courseCode.isNotEmpty)
              Text(s.courseCode,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: onSurface)),
            const SizedBox(height: 6),
            Text('Lecturer: '
                '${s.lecturerName.isNotEmpty ? s.lecturerName : s.lecturerStaffId.isNotEmpty ? s.lecturerStaffId : '—'}'),
            Text(
                'Timetabled: ${s.room.isNotEmpty ? s.room : 'no room'} at ${s.startTime}',
                style: theme.textTheme.bodySmall?.copyWith(color: onSurface)),
            if (s.cohort.isNotEmpty)
              Text(s.cohort,
                  style: theme.textTheme.bodySmall?.copyWith(color: onSurface)),
            if (s.alsoHere.isNotEmpty) ...[
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('This hour also covers',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(fontWeight: FontWeight.w600)),
                    for (final line in s.alsoHere.split(' | '))
                      Text('• $line', style: theme.textTheme.bodySmall),
                    const SizedBox(height: 4),
                    Text(
                      'Your verdict records THIS unit. Tick the others as well so '
                      'their students are not left without a record.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 14),
            CheckboxListTile(
              value: _isComp,
              onChanged: (v) => setState(() => _isComp = v ?? false),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('This is a compensation lecture',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              subtitle: const Text('Making good a lecture that did not happen'),
              dense: true,
            ),
            if (_isComp)
              TextField(
                onChanged: (v) => setState(() => _compFor = v),
                decoration: const InputDecoration(
                  labelText: 'For the lecture of (YYYY-MM-DD, optional)',
                  border: OutlineInputBorder(),
                ),
              ),
            const SizedBox(height: 20),
            Text('Is the lecturer teaching?',
                style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: SizedBox(
                  height: 56,
                  child: FilledButton(
                    onPressed: () => _decide(true),
                    child: const Text('✓  Yes',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SizedBox(
                  height: 56,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: theme.colorScheme.error,
                    ),
                    onPressed: () => _decide(false),
                    child: const Text('✗  No',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  ),
                ),
              ),
            ]),
            const SizedBox(height: 18),
            CheckboxListTile(
              value: _moved,
              onChanged: (v) => setState(() => _moved = v ?? false),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('Found somewhere else?',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              subtitle: const Text(
                  'Different room, time or day — the lecturer, their HOD and QA are told.'),
              dense: true,
            ),
            if (_moved) ...[
              const SizedBox(height: 8),
              TextField(
                onChanged: (v) => setState(() => _venue = v),
                decoration: const InputDecoration(
                  labelText: 'Room where you found it',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: TextField(
                    onChanged: (v) => setState(() => _time = v),
                    decoration: const InputDecoration(
                      labelText: 'Start (HH:MM)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    onChanged: (v) => setState(() => _date = v),
                    decoration: const InputDecoration(
                      labelText: 'Date',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ]),
              const SizedBox(height: 8),
              TextField(
                onChanged: (v) => setState(() => _remarks = v),
                decoration: const InputDecoration(
                  labelText: 'Note (optional)',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}