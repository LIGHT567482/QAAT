import 'package:flutter/material.dart';

import '../../patrol/fingerprint.dart';
import '../../patrol/patrol_client.dart';
import '../../patrol/patrol_models.dart';
import 'patrol_round_tab.dart' show todayDate;

/// MANUAL ATTENDANCE — the lecture that was taught but never timetabled.
///
/// The round is generated from the timetable, so every tick is ABOUT a slot. A
/// great many real lectures have no slot: a unit added after the schedule was
/// locked, a make-up hour agreed in a corridor, a class moved into a free room, a
/// visiting lecturer covering a week. Standing in front of one of those, a monitor
/// could previously do nothing, or tick whichever slot looked closest — which files
/// a true observation under the wrong lecture, and that is worse than the silence.
///
/// EVERY FIELD IS PICK-OR-TYPE, and that is the whole design. A list alone would
/// refuse to record the exact lectures this exists for (the unit not yet in the
/// curriculum, the lecturer hired last week). Free text alone would produce a drift
/// of near-miss spellings that no report can group. So the known list is offered
/// first and a typed value is always accepted — and picking a unit fills in its
/// class/group and college, because the monitor should not retype what the system
/// knows.
class ManualAttendanceSheet extends StatefulWidget {
  const ManualAttendanceSheet({super.key, required this.token, this.title});

  final String token;

  /// Header text; the room round hands in "Attendance taken manually".
  final String? title;

  @override
  State<ManualAttendanceSheet> createState() => _ManualAttendanceSheetState();
}

class _ManualAttendanceSheetState extends State<ManualAttendanceSheet> {
  PatrolReference _ref = const PatrolReference();
  bool _loading = true;
  bool _busy = false;
  String? _error;

  String _roomId = '';
  String _roomText = '';
  String _unitId = '';
  String _unitText = '';
  String _lecturerId = '';
  String _lecturerText = '';
  String _classGroup = '';
  String _school = '';

  // "" while the school/department was typed or inherited, the exact name while it
  // matches a known list entry — what uses to say "from the list" rather than "typed".
  String _schoolId = '';
  String _department = '';
  String _departmentId = '';
  String _students = '';
  String _remarks = '';
  bool _isComp = false;

  // The lecture being made good: a real date and a real time, both required. Free
  // text here is what made the old field decorative — "last week" cannot be matched
  // to any missed lecture.
  String _compDate = ''; // YYYY-MM-DD
  String _compTime = ''; // HH:MM

  // When the lecture RUNS, both ends. The start alone says nothing about what the
  // hour was worth.
  late String _begins;
  String _ends = '';

  // The OTHER unit codes this same hour delivered.
  List<ExtraUnit> _extras = [];

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _begins = '${now.hour.toString().padLeft(2, '0')}'
        ':${now.minute.toString().padLeft(2, '0')}';
    _loadReference();
  }

  Future<void> _loadReference() async {
    if (widget.token.isNotEmpty) {
      _ref = await PatrolClient()
          .reference(widget.token, await DeviceFingerprint.get());
    }
    if (mounted) setState(() => _loading = false);
  }

  /// A value only counts as "from the list" when it EXACTLY matches a known entry —
  /// a college inherited from a course that spells it differently must not read as
  /// a pick the monitor made.
  String _knownId(List<RefItem> options, String value) {
    final t = value.trim();
    if (t.isEmpty) return '';
    return options.firstWhere((o) => o.label.toLowerCase() == t.toLowerCase(),
        orElse: () => const RefItem('', '')).label;
  }

  /// Picking a unit carries its cohort and college across, so the two fields the
  /// monitor would otherwise have to know off by heart arrive filled in — still
  /// editable, because the whole point of this form is the case where the curriculum
  /// is not the last word.
  void _chooseUnit(RefItem? item) {
    setState(() {
      _unitId = item?.id ?? '';
      _unitText = item?.label ?? '';
      final d = _ref.unitDefaults[item?.id];
      if (d != null) {
        if (_classGroup.isEmpty) _classGroup = d.$1;
        if (_school.isEmpty) _school = d.$2;
      }
      final dept = _ref.unitDepartments[item?.id];
      if ((dept ?? '').isNotEmpty) {
        if (_department.isEmpty) {
          _department = dept!;
          if (_school.isEmpty) {
            final c = _ref.departments
                .firstWhere((o) => o.label.toLowerCase() == dept.toLowerCase(),
                    orElse: () => const RefItem('', ''));
            _school = c.extra;
          }
        }
      }
      _departmentId = _knownId(_ref.departments, _department);
      _schoolId = _knownId(_schoolOptions, _school);
    });
  }

  /// Picking a lecturer brings his department and home college across — both sit in
  /// the registry and the monitor should not retype what the system knows. Fills
  /// only while blank, and the college may still come via the department when the
  /// lecturer's own record carries no school.
  void _chooseLecturer(RefItem? item) {
    setState(() {
      _lecturerId = item?.id ?? '';
      _lecturerText = item?.label ?? '';
      final dept = item?.extra ?? '';
      if (dept.isNotEmpty && _department.isEmpty) _department = dept;
      if (_school.isEmpty) {
        _school = _lecturerId.isNotEmpty
            ? (_ref.lecturerSchools[_lecturerId] ?? '')
            : '';
        if (_school.isEmpty) {
          _school = _ref.departments
              .firstWhere((o) => o.label.toLowerCase() == _department.toLowerCase(),
                  orElse: () => const RefItem('', ''))
              .extra;
        }
      }
      _departmentId = _knownId(_ref.departments, _department);
      _schoolId = _knownId(_schoolOptions, _school);
    });
  }

  List<RefItem> get _schoolOptions =>
      [for (final s in _ref.schools) RefItem(s, s)];

  bool get _badSpan =>
      _ends.isNotEmpty && !endsAfterHHMM(_begins, _ends);

  bool get _blocked =>
      _badSpan || (_isComp && (_compDate.isEmpty || _compTime.isEmpty));

  List<String> _distinct(Iterable<String> xs) {
    final seen = <String>{};
    final out = <String>[];
    for (final x in xs) {
      final t = x.trim();
      if (t.isEmpty || seen.contains(t.toLowerCase())) continue;
      seen.add(t.toLowerCase());
      out.add(t);
    }
    return out;
  }

  Future<void> _submit(bool teaching) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    if (widget.token.isEmpty) {
      setState(() {
        _error = 'Not signed in';
        _busy = false;
      });
      return;
    }
    final entry = ManualEntry(
      roomId: _roomId,
      room: _roomText,
      unitId: _unitId,
      unitName: _unitText,
      lecturerStaffId: _lecturerId,
      lecturerName: _lecturerText,
      classGroup: _classGroup.trim(),
      school: _school.trim(),
      department: _department.trim(),
      studentsCounted: int.tryParse(_students) ?? 0,
      sessionDate: todayDate(),
      timeOfDay: _begins,
      endTime: _ends,
      taught: teaching,
      remarks: _remarks.trim(),
      isCompensation: _isComp,
      compensationForAt: _isComp ? '$_compDate $_compTime' : '',
      alsoUnits: _extras,
    );
    String? msg;
    try {
      msg = await PatrolClient()
          .manual(widget.token, await DeviceFingerprint.get(), entry);
    } on PatrolDeviceRejected catch (e) {
      msg = e.message;
    } on Object {
      msg = 'Could not record it';
    }
    if (!mounted) return;
    if (msg == null) {
      Navigator.of(context)
          .pop('Recorded — ${_unitText.isNotEmpty ? _unitText : _unitId}');
    } else {
      setState(() {
        _error = msg;
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurfaceVariant;

    final colleges =
        _distinct([_school, ..._extras.map((e) => e.school)]);
    final departments =
        _distinct([_department, ..._extras.map((e) => e.department)]);

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.title ?? 'Attendance taken manually',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(
                'For a lecture that is happening but is not on the timetable. Pick '
                'from the lists where you can, type where you cannot.',
                style: theme.textTheme.bodySmall?.copyWith(color: onSurface),
              ),
            ),
            if (_loading)
              Row(children: [
                const SizedBox(
                    width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 10),
                Text('Loading rooms, units and lecturers…',
                    style: theme.textTheme.bodySmall),
              ]),
            if (_error != null)
              Text(_error!,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error)),
            const SizedBox(height: 8),
            PickOrType(
              label: 'Room',
              options: _ref.rooms,
              selectedId: _roomId,
              typed: _roomText,
              onPick: (item) => setState(() {
                _roomId = item?.id ?? '';
                _roomText = item?.label ?? '';
              }),
              onType: (v) => setState(() {
                _roomText = v;
                _roomId = '';
              }),
            ),
            const SizedBox(height: 8),
            PickOrType(
              label: 'Course unit',
              options: _ref.units,
              selectedId: _unitId,
              typed: _unitText,
              onPick: _chooseUnit,
              onType: (v) => setState(() {
                _unitText = v;
                _unitId = '';
              }),
            ),
            const SizedBox(height: 8),
            TextField(
              onChanged: (v) => setState(() => _classGroup = v),
              decoration: const InputDecoration(
                labelText: 'Class / Group  (e.g. 2:1)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            PickOrType(
              label: 'Lecturer',
              options: _ref.lecturers,
              selectedId: _lecturerId,
              typed: _lecturerText,
              onPick: _chooseLecturer,
              onType: (v) => setState(() {
                _lecturerText = v;
                _lecturerId = '';
              }),
            ),
            const SizedBox(height: 8),
            TextField(
              onChanged: (v) => setState(() {
                final d = v.replaceAll(RegExp(r'\D'), '');
                _students = d.length > 4 ? _students : d;
              }),
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Number of students in the room',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            PickOrType(
              label: 'School / College',
              options: _schoolOptions,
              selectedId: _schoolId,
              typed: _school,
              note: (_unitId.isNotEmpty || _lecturerId.isNotEmpty)
                  ? 'Taken from the unit or lecturer you picked — change it if it is wrong.'
                  : 'Pick the college, or type it if it is not listed.',
              onPick: (s) => setState(() {
                if (s != null) {
                  _school = s.label;
                  _schoolId = s.id;
                }
              }),
              onType: (v) => setState(() {
                _school = v;
                _schoolId = '';
              }),
            ),
            const SizedBox(height: 8),
            PickOrType(
              label: 'Department',
              options: _ref.departments,
              selectedId: _departmentId,
              typed: _department,
              note: 'Picking one brings its college — two codes for a lecture '
                  'usually share a college and differ by department.',
              onPick: (d) => setState(() {
                if (d != null) {
                  _department = d.label;
                  _departmentId = d.id;
                  if (_school.isEmpty) {
                    _school = d.extra;
                    _schoolId = _knownId(_schoolOptions, _school);
                  }
                }
              }),
              onType: (v) => setState(() {
                _department = v;
                _departmentId = '';
              }),
            ),
            const SizedBox(height: 14),
            _ExtraUnitsSection(
              ref: _ref,
              extras: _extras,
              primaryUnitId: _unitId,
              primarySchool: _school,
              onChange: (v) => setState(() => _extras = v),
            ),
            if (colleges.length > 1 || departments.length > 1) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('This lecture spans',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(fontWeight: FontWeight.w600)),
                    if (colleges.isNotEmpty)
                      Text('Colleges: ${colleges.join(', ')}',
                          style: theme.textTheme.bodySmall),
                    if (departments.isNotEmpty)
                      Text('Departments: ${departments.join(', ')}',
                          style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 14),
            Text('Lecture time',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: _TimeField('Begins', _begins, (v) => setState(() => _begins = v))),
              const SizedBox(width: 8),
              Expanded(child: _TimeField('Ends', _ends, (v) => setState(() => _ends = v))),
            ]),
            if (_badSpan)
              Text('The end has to be after the start.',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error)),
            const SizedBox(height: 4),
            CheckboxListTile(
              value: _isComp,
              onChanged: (v) => setState(() => _isComp = v ?? false),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              dense: true,
              title: const Text('This is a compensation lecture',
                  style: TextStyle(fontWeight: FontWeight.w600)),
            ),
            if (_isComp) ...[
              Text('Which lecture is this making good?',
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(child: _DateField('Its date', _compDate, (v) => setState(() => _compDate = v))),
                const SizedBox(width: 8),
                Expanded(child: _TimeField('It began at', _compTime, (v) => setState(() => _compTime = v))),
              ]),
              Text(
                (_compDate.isEmpty || _compTime.isEmpty)
                    ? 'Both are needed. Without the time, a Tuesday with two '
                        'lectures cannot say which one this replaces.'
                    : 'Making good the lecture of $_compDate at $_compTime.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: (_compDate.isEmpty || _compTime.isEmpty)
                      ? theme.colorScheme.error
                      : onSurface,
                ),
              ),
            ],
            const SizedBox(height: 8),
            TextField(
              onChanged: (v) => setState(() => _remarks = v),
              decoration: const InputDecoration(
                labelText: 'Remarks (optional)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Recorded as today, $_begins${_ends.isNotEmpty ? '–$_ends' : ''}.',
              style: theme.textTheme.bodySmall?.copyWith(color: onSurface),
            ),
            const SizedBox(height: 14),
            // The verdict is still two deliberate buttons rather than a toggle and a
            // Save, for the same reason it is on the round.
            Text('Is the lecturer teaching?',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: SizedBox(
                  height: 54,
                  child: FilledButton(
                    onPressed: !_busy && !_blocked ? () => _submit(true) : null,
                    child: const Text('✓  Teaching',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SizedBox(
                  height: 54,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: theme.colorScheme.error,
                    ),
                    onPressed: !_busy && !_blocked ? () => _submit(false) : null,
                    child: const Text('✗  Not teaching',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}

/// One field that is a dropdown AND a text box.
///
/// Two controls for one fact would be a trap — the monitor fills in the box, ignores
/// the list, and the form has to guess which they meant. Here they are the same
/// field: choosing from the list writes the text, and editing the text clears the
/// choice, so what is on screen is always exactly what will be sent.
class PickOrType extends StatefulWidget {
  const PickOrType({
    super.key,
    required this.label,
    required this.options,
    required this.selectedId,
    required this.typed,
    required this.onPick,
    required this.onType,
    this.note,
  });

  final String label;
  final List<RefItem> options;
  final String selectedId;
  final String typed;
  final ValueChanged<RefItem?> onPick;
  final ValueChanged<String> onType;
  final String? note;

  @override
  State<PickOrType> createState() => _PickOrTypeState();
}

class _PickOrTypeState extends State<PickOrType> {
  bool _open = false;

  List<RefItem> get _matches {
    final t = widget.typed;
    if (t.isEmpty) return widget.options.take(60).toList();
    final n = t.toLowerCase();
    return widget.options
        .where((o) =>
            o.label.toLowerCase().contains(n) || o.id.toLowerCase().contains(n))
        .take(60)
        .toList();
  }

  String get _origin => switch ((widget.selectedId.isNotEmpty, widget.typed.isNotEmpty)) {
        (true, _) => 'From the list: ${widget.selectedId}',
        (_, true) => 'Typed — not on the list, which is allowed',
        _ => 'Choose one, or type it',
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final notes = [if (_origin.isNotEmpty) _origin, if (widget.note != null) widget.note!];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          onChanged: (v) {
            widget.onType(v);
            setState(() => _open = true);
          },
          onTap: () => setState(() => _open = !_open),
          decoration: InputDecoration(
            labelText: widget.label,
            border: const OutlineInputBorder(),
            suffixIcon: const Icon(Icons.arrow_drop_down),
            helperText: notes.join('  ·  '),
          ),
        ),
        if (_open)
          Material(
            elevation: 3,
            borderRadius: BorderRadius.circular(8),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 280),
              child: ListView(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                children: [
                  if (_matches.isEmpty)
                    ListTile(
                      dense: true,
                      title: const Text('Nothing matches — what you typed will be used'),
                      onTap: () => setState(() => _open = false),
                    ),
                  for (final item in _matches)
                    ListTile(
                      dense: true,
                      title: Text(item.label),
                      subtitle: (item.id.isNotEmpty || item.extra.isNotEmpty)
                          ? Text(
                              [item.id, item.extra].where((s) => s.isNotEmpty).join(' · '),
                              style: theme.textTheme.bodySmall
                                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                            )
                          : null,
                      onTap: () {
                        widget.onPick(item);
                        setState(() => _open = false);
                      },
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// THE OTHER UNIT CODES THIS SAME HOUR DELIVERS. See the header of the sheet — one
/// class genuinely delivers several codes, and each must get a record.
class _ExtraUnitsSection extends StatefulWidget {
  const _ExtraUnitsSection({
    required this.ref,
    required this.extras,
    required this.onChange,
    required this.primaryUnitId,
    required this.primarySchool,
  });

  final PatrolReference ref;
  final List<ExtraUnit> extras;
  final ValueChanged<List<ExtraUnit>> onChange;
  final String primaryUnitId;
  final String primarySchool;

  @override
  State<_ExtraUnitsSection> createState() => _ExtraUnitsSectionState();
}

class _ExtraUnitsSectionState extends State<_ExtraUnitsSection> {
  void _replace(int i, ExtraUnit updated) {
    final l = List<ExtraUnit>.of(widget.extras);
    l[i] = updated;
    widget.onChange(l);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurfaceVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Other course units in this same lecture',
            style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
        Text(
          'Add the other codes this hour also covers, so their students are not '
          'left without a record.',
          style: theme.textTheme.bodySmall?.copyWith(color: onSurface),
        ),
        for (var i = 0; i < widget.extras.length; i++) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(children: [
                  Expanded(
                    child: Text('Unit ${i + 2}',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(fontWeight: FontWeight.w600)),
                  ),
                  TextButton(
                    onPressed: () => widget.onChange(
                        [for (var j = 0; j < widget.extras.length; j++) if (j != i) widget.extras[j]]),
                    child: const Text('Remove'),
                  ),
                ]),
                PickOrType(
                  label: 'Course unit',
                  options: widget.ref.units,
                  selectedId: widget.extras[i].unitId,
                  typed: widget.extras[i].unitName,
                  onPick: (item) {
                    final id = item?.id ?? '';
                    final d = widget.ref.unitDefaults[id];
                    _replace(
                      i,
                      ExtraUnit(
                        unitId: id,
                        unitName: item?.label ?? '',
                        classGroup: widget.extras[i].classGroup.isEmpty
                            ? (d?.$1 ?? '')
                            : widget.extras[i].classGroup,
                        school: widget.extras[i].school.isEmpty
                            ? ((d?.$2 ?? '').isNotEmpty ? d!.$2 : widget.primarySchool)
                            : widget.extras[i].school,
                        department: widget.extras[i].department.isEmpty
                            ? (widget.ref.unitDepartments[id] ?? '')
                            : widget.extras[i].department,
                      ),
                    );
                  },
                  onType: (t) => _replace(i,
                      ExtraUnit(unitName: t, unitId: '', classGroup: widget.extras[i].classGroup, school: widget.extras[i].school, department: widget.extras[i].department)),
                ),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(
                    child: TextField(
                      onChanged: (v) => _replace(i, ExtraUnit(
                          unitId: widget.extras[i].unitId,
                          unitName: widget.extras[i].unitName,
                          classGroup: v,
                          school: widget.extras[i].school,
                          department: widget.extras[i].department)),
                      decoration: const InputDecoration(
                        labelText: 'Class / Group',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      onChanged: (v) => _replace(i, ExtraUnit(
                          unitId: widget.extras[i].unitId,
                          unitName: widget.extras[i].unitName,
                          classGroup: widget.extras[i].classGroup,
                          school: widget.extras[i].school,
                          department: v)),
                      decoration: const InputDecoration(
                        labelText: 'Department',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                ]),
                const SizedBox(height: 8),
                TextField(
                  onChanged: (v) => _replace(i, ExtraUnit(
                      unitId: widget.extras[i].unitId,
                      unitName: widget.extras[i].unitName,
                      classGroup: widget.extras[i].classGroup,
                      school: v,
                      department: widget.extras[i].department)),
                  decoration: InputDecoration(
                    labelText: 'School / College',
                    helperText: widget.extras[i].school.isNotEmpty &&
                            widget.extras[i].school.toLowerCase() ==
                                widget.primarySchool.toLowerCase()
                        ? 'Same college as the first unit — it is recorded once.'
                        : 'A different college from the first unit.',
                    border: const OutlineInputBorder(),
                  ),
                ),
                if (widget.extras[i].unitId.isNotEmpty &&
                    widget.extras[i].unitId
                        .toLowerCase() ==
                        widget.primaryUnitId.toLowerCase())
                  Text('This is the same unit as the first one — it will not be '
                      'recorded twice.',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.error)),
              ],
            ),
          ),
        ],
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: () => widget.onChange(
              [...widget.extras, ExtraUnit(school: widget.primarySchool)]),
          child: Text(widget.extras.isEmpty
              ? '+ Add another course unit'
              : '+ Add one more'),
        ),
      ],
    );
  }
}

/// A time field that only ever holds HH:MM. Typed digits are shaped as they are
/// entered, so the form cannot carry prose where the record needs a clock time.
class _TimeField extends StatelessWidget {
  const _TimeField(this.label, this.value, this.onChange);
  final String label;
  final String value;
  final ValueChanged<String> onChange;

  @override
  Widget build(BuildContext context) {
    return TextField(
      onChanged: (raw) {
        final d = raw.replaceAll(RegExp(r'\D'), '');
        if (d.length > 4) return;
        onChange(d.length <= 2
            ? d
            : '${d.substring(0, 2)}:${d.substring(2)}');
      },
      keyboardType: TextInputType.number,
      decoration: InputDecoration(
        labelText: label,
        hintText: 'HH:MM',
        errorText: value.isNotEmpty && !isHHMM(value)
            ? 'Use HH:MM'
            : null,
        border: const OutlineInputBorder(),
      ),
    );
  }
}

/// A date field that only ever holds YYYY-MM-DD, for the same reason.
class _DateField extends StatelessWidget {
  const _DateField(this.label, this.value, this.onChange);
  final String label;
  final String value;
  final ValueChanged<String> onChange;

  @override
  Widget build(BuildContext context) {
    return TextField(
      onChanged: (raw) {
        final d = raw.replaceAll(RegExp(r'\D'), '');
        if (d.length > 8) return;
        onChange(d.length <= 4
            ? d
            : d.length <= 6
                ? '${d.substring(0, 4)}-${d.substring(4)}'
                : '${d.substring(0, 4)}-${d.substring(4, 6)}-${d.substring(6)}');
      },
      keyboardType: TextInputType.number,
      decoration: InputDecoration(
        labelText: label,
        hintText: 'YYYY-MM-DD',
        errorText: value.isNotEmpty && !_isDate(value)
            ? 'Use YYYY-MM-DD'
            : null,
        border: const OutlineInputBorder(),
      ),
    );
  }

  static bool _isDate(String s) {
    final parts = s.split('-');
    if (parts.length != 3) return false;
    final y = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    final d = int.tryParse(parts[2]);
    if (y == null || m == null || d == null) return false;
    final t = DateTime(y, m, d);
    return t.year == y && t.month == m && t.day == d;
  }
}

bool isHHMM(String s) {
  if (s.length != 5 || s[2] != ':') return false;
  final h = int.tryParse(s.substring(0, 2)) ?? 99;
  final m = int.tryParse(s.substring(3, 5)) ?? 99;
  return h >= 0 && h <= 23 && m >= 0 && m <= 59;
}

int _hhmmToMinutes(String s) {
  if (!isHHMM(s)) return -1;
  return int.parse(s.substring(0, 2)) * 60 + int.parse(s.substring(3, 5));
}

/// A class that "ends" before it began is a typo, and storing it would put a
/// negative hour into contact-time reporting.
bool endsAfterHHMM(String begins, String ends) {
  final b = _hhmmToMinutes(begins);
  final e = _hhmmToMinutes(ends);
  return b >= 0 && e >= 0 && e > b;
}