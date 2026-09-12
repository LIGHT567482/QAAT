import 'package:flutter/material.dart';

import '../../net/coordinator_client.dart';
import '../../net/net.dart';
import 'app_state.dart';
import 'free_room_picker.dart';

T? _firstOrNull<T>(Iterable<T> items) {
  final it = items.iterator;
  return it.moveNext() ? it.current : null;
}

/// Pick today's unit and open the register — a faithful port of the native
/// `OpenSessionScreen`. The coordinator picks the unit (today's timetabled ones,
/// or a deliberate off-timetable lecture), may declare a provision room when the
/// timetabled one can't be used, then taps "Open register" which creates the
/// ACTIVE session and returns the code to read out.
///
/// Returns a [TodaySession] on success, null on cancel.
class OpenRegisterScreen extends StatefulWidget {
  const OpenRegisterScreen({super.key, required this.token, this.client});

  final String token;
  final CoordinatorClient? client;

  @override
  State<OpenRegisterScreen> createState() => _OpenRegisterScreenState();
}

class _OpenRegisterScreenState extends State<OpenRegisterScreen> {
  late final CoordinatorClient _client = widget.client ?? const CoordinatorClient();
  var _offTimetable = false;
  String? _selectedUnitId;
  ProvisionalRoom? _provision;
  var _opening = false;
  String? _err;
  String? _manifestMissing;

  @override
  void initState() {
    super.initState();
    final units = _allUnits;
    if (units.isNotEmpty) {
      _selectedUnitId = _firstOrNull(_shownUnits)?.unitId ?? units.first.unitId;
    } else {
      _manifestMissing =
          "Today's schedule hasn't loaded yet. Tap the ⟳ at the top-right to "
          'refresh (needs internet once — your session may have expired).';
    }
  }

  List<CoordUnit> get _allUnits => CoordinatorState.overview.value?.displayUnits ?? const [];

  List<CoordUnit> get _shownUnits {
    if (_offTimetable) return _allUnits;
    final today = DateTime.now().weekday;
    return _allUnits
        .where((u) => u.dayOfWeek == today && _startMinutes(u.start) != null)
        .toList();
  }

  int? _startMinutes(String hhmm) {
    final p = hhmm.split(':');
    final h = int.tryParse(p.first);
    final m = p.length > 1 ? int.tryParse(p[1]) : 0;
    if (h == null || m == null) return null;
    return h * 60 + m;
  }

  Future<void> _pickRoom() async {
    final picked = await showFreeRoomPicker(
      context,
      token: widget.token,
      client: _client,
    );
    if (picked != null && mounted) {
      setState(() => _provision = picked);
    }
  }

  Future<void> _open() async {
    setState(() {
      _opening = true;
      _err = null;
    });
    final unit =
        _firstOrNull(_shownUnits.where((u) => u.unitId == _selectedUnitId));
    if (unit == null) {
      setState(() => _opening = false);
      return;
    }
    final session = await _create(unit);
    if (session == null) {
      if (mounted) setState(() => _opening = false);
      return;
    }
    if (!mounted) return;
    CoordinatorState.todaySession.value = TodaySession(
      sessionId: session.sessionId,
      unitId: unit.unitId,
      unitName: unit.name,
      studentCode: session.studentCode,
      windowEnd: session.windowEnd,
    );
    Navigator.of(context).pop();
  }

  Future<SessionOpened?> _create(CoordUnit unit) async {
    try {
      return await _client.createSession(
        widget.token,
        unit.unitId,
        venueId: _provision?.room.venueId ?? '',
        roomIsProvision: _provision != null,
        provisionNote: _provision?.reason ?? '',
        unscheduled: _offTimetable,
      );
    } on NetFailure catch (f) {
      _fail(f.message);
      return null;
    } on Object catch (e) {
      _fail(Net.friendly(e));
      return null;
    }
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _err = message;
      _opening = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final units = _shownUnits;

    return Scaffold(
      backgroundColor: appBackground(context),
      appBar: AppBar(title: const Text('Take attendance')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_manifestMissing != null)
            Text(
              _manifestMissing!,
              style: TextStyle(color: scheme.error),
            )
          else if (units.isEmpty && !_offTimetable) ...[
            Text(
              'No unit is timetabled for today.',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            Text(
              'If a lecture is happening anyway — a make-up class, a unit added '
              'after the schedule was set — you can still take attendance for it. '
              'Students check in exactly as they always do; the record simply '
              'notes it was off-timetable.',
              style: theme.textTheme.labelMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: () => setState(() => _offTimetable = true),
              child: const Text('Take attendance for an off-timetable lecture'),
            ),
          ] else ...[
            if (_offTimetable)
              Card(
                color: scheme.secondaryContainer,
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Off-timetable lecture',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      Text(
                        'Every unit of your cohort is listed. Students check in '
                        'normally; the attendance record will say this lecture '
                        'was not on the timetable.',
                        style: theme.textTheme.labelSmall,
                      ),
                      TextButton(
                        onPressed: () => setState(() => _offTimetable = false),
                        child: const Text("Back to today's timetable"),
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 12),
            if (_provision != null) ...[
              Card(
                color: scheme.secondaryContainer,
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Running in ${_provision!.room.name} (provision)',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      Text(
                        '${_provision!.reason.isNotEmpty ? '${_provision!.reason} · ' : ''}'
                        'QA monitors have been told where to find this lecture.',
                        style: theme.textTheme.labelSmall,
                      ),
                      TextButton(
                        onPressed: () => setState(() => _provision = null),
                        child: const Text('Use the timetabled room instead'),
                      ),
                    ],
                  ),
                ),
              ),
            ] else
              TextButton.icon(
                onPressed: _pickRoom,
                icon: const Icon(Icons.meeting_room_outlined, size: 18),
                label: const Text('Timetabled room unavailable? Find a free one'),
              ),
            const SizedBox(height: 8),
            Text(
              'Which unit',
              style: theme.textTheme.titleSmall,
            ),
            RadioGroup<String>(
              groupValue: _selectedUnitId,
              onChanged: (v) => setState(() => _selectedUnitId = v),
              child: Column(
                children: [
                  for (final u in units)
                    RadioListTile<String>(
                      value: u.unitId,
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        u.name,
                        style: const TextStyle(fontSize: 14),
                      ),
                      subtitle: Text(
                        '${u.start}'
                        '${u.lecturers.isNotEmpty ? ' · ${u.lecturers}' : ''}',
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Opening pins the lecture to where you are standing and gives you '
              'a code to read to the class. Students type the code; their phones '
              'must be nearby to be accepted.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            if (_err != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _err!,
                  style: TextStyle(color: scheme.error),
                ),
              ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _opening || _selectedUnitId == null ? null : _open,
              child: Text(_opening ? 'Opening…' : 'Open register'),
            ),
          ],
        ],
      ),
    );
  }
}

Color appBackground(BuildContext context) =>
    Theme.of(context).colorScheme.surface;