import 'package:flutter/material.dart';

import '../../net/auth_client.dart';
import '../../net/coordinator_client.dart';
import 'app_state.dart';
import 'timetable_grid.dart';

const List<String> kDays = ['', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// The coordinator home — a faithful port of the native `DashboardScreen`: a
/// welcome, the genuinely-unassigned banner, the live-sessions panel (with its
/// Close button), and Timetable / Units tabs. Data reloads on every ⟳.
class CoordinatorHomeTab extends StatefulWidget {
  const CoordinatorHomeTab({super.key, required this.result, this.client});

  final LoginResult result;
  final CoordinatorClient? client;

  @override
  State<CoordinatorHomeTab> createState() => _CoordinatorHomeTabState();
}

class _CoordinatorHomeTabState extends State<CoordinatorHomeTab> {
  late final CoordinatorClient _client = widget.client ?? CoordinatorState.client;
  var _loaded = false;
  var _tab = 0;
  String? _closing;

  LoginResult get _r => widget.result;

  @override
  void initState() {
    super.initState();
    CoordinatorState.refreshTick.addListener(_reload);
    _reload();
  }

  @override
  void dispose() {
    CoordinatorState.refreshTick.removeListener(_reload);
    super.dispose();
  }

  Future<void> _reload() async {
    await CoordinatorState.refreshOverview(_r);
    await CoordinatorState.refreshActive(_r);
    if (mounted) setState(() => _loaded = true);
  }

  Future<void> _closeSession(ActiveSession s) async {
    setState(() => _closing = s.sessionId);
    await _client.closeSession(_r.token, s.sessionId);
    await CoordinatorState.refreshActive(_r);
    if (mounted) setState(() => _closing = null);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final overview = CoordinatorState.overview.value;
    final active = CoordinatorState.activeSessions.value;

    final hasCohort = (overview?.units.isNotEmpty == true) ||
        (overview?.slots.isNotEmpty == true) ||
        (CoordinatorState.cohortLabel.value?.isNotEmpty ?? false);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Welcome, ${_displayName()} 👋',
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
        Text(
          "Tap ⟳ (top-right) to download today's data, then take attendance "
          'even with no internet.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),

        if (overview?.offering == null && _loaded && !hasCohort) ...[
          Card(
            color: scheme.tertiaryContainer,
            child: const Padding(
              padding: EdgeInsets.all(14),
              child: Text(
                'You are not yet assigned to a session. Ask your administrator '
                'to add you as a coordinator of a session.',
                style: TextStyle(fontSize: 13),
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],

        if (active.isNotEmpty) ...[
          Card(
            color: scheme.secondaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '● Live session${active.length > 1 ? 's' : ''} in progress',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  for (final s in active)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  s.unitName,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                Text(
                                  '${s.awaitingLecturer ? 'Awaiting lecturer' : 'Active'}'
                                  ' · ${s.presentCount} checked in',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          FilledButton(
                            onPressed: _closing == s.sessionId
                                ? null
                                : () => _closeSession(s),
                            style: FilledButton.styleFrom(
                              backgroundColor: scheme.error,
                              foregroundColor: scheme.onError,
                            ),
                            child: Text(
                              _closing == s.sessionId ? 'Closing…' : 'Close',
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],

        _InnerTabs(
          title: 'Timetable',
          countLabel: _unitsTitle(overview),
          selected: _tab,
          onSelect: (i) => setState(() => _tab = i),
        ),
        const SizedBox(height: 10),
        _tab == 0
            ? TimetableView(
                units: overview?.displayUnits ?? const [],
                sessionType: overview?.offering?.sessionType ?? '',
              )
            : UnitsView(units: overview?.displayUnits ?? const []),

        const SizedBox(height: 20),
        const Divider(),
        const SizedBox(height: 10),
        Text(
          'Sync status is in the Sync tab below.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  String _displayName() {
    final titled =
        [widget.result.title, widget.result.fullName]
            .where((s) => s.isNotEmpty)
            .join(' ')
            .trim();
    return titled.isNotEmpty ? titled : 'Coordinator';
  }

  String _unitsTitle(CoordOverview? o) {
    final n = o?.displayUnits.length ?? 0;
    return 'Units ($n)';
  }
}

/// The two inner tabs (Timetable / Units) exactly as the native screen orders
/// them — the Students/Last-roster tab pair is STUDENT-MODULE-DEFERRED there too.
class _InnerTabs extends StatelessWidget {
  const _InnerTabs({
    required this.title,
    required this.countLabel,
    required this.selected,
    required this.onSelect,
  });

  final String title;
  final String countLabel;
  final int selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const labels = ['Timetable', 'Units'];
    return Row(
      children: [
        for (final (i, l) in labels.indexed)
          Expanded(
            child: InkWell(
              onTap: () => onSelect(i),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      width: 2,
                      color: selected == i
                          ? scheme.primary
                          : scheme.outlineVariant,
                    ),
                  ),
                ),
                alignment: Alignment.center,
                child: Text(
                  l,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: selected == i
                        ? FontWeight.w700
                        : FontWeight.w500,
                    color: selected == i
                        ? scheme.primary
                        : scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// The week drawn by the shared [TimetableGrid]; maps units onto it.
class TimetableView extends StatelessWidget {
  const TimetableView({
    super.key,
    required this.units,
    required this.sessionType,
  });

  final List<CoordUnit> units;
  final String sessionType;

  @override
  Widget build(BuildContext context) {
    final scheduled =
        units.where((u) => u.dayOfWeek >= 1 && u.dayOfWeek <= 7 && u.start.isNotEmpty).toList();
    final unscheduled =
        units.where((u) => !(u.dayOfWeek >= 1 && u.dayOfWeek <= 7 && u.start.isNotEmpty)).toList();
    if (scheduled.isEmpty && unscheduled.isEmpty) {
      return _emptyNote(
        context,
        'No units in this session yet. Ask your admin to add units, then set '
        "each unit's day & time when you open it.",
      );
    }
    return TimetableGrid(
      entries: [
        for (final u in scheduled)
          TtEntry(
            name: u.name,
            dayOfWeek: u.dayOfWeek,
            start: u.start,
            durationMin: u.durationMin,
            detail: [
              if (u.room.isNotEmpty) u.room,
              if (u.lecturers.isNotEmpty) u.lecturers,
              if (u.lecturerPhone.isNotEmpty) '☎ ${u.lecturerPhone}',
            ].join(' · '),
          ),
      ],
      sessionType: sessionType,
      unscheduledNames: unscheduled.map((u) => u.name).toList(),
    );
  }
}

/// Today-first unit list with a "show all" toggle, exactly like the native view.
class UnitsView extends StatefulWidget {
  const UnitsView({super.key, required this.units});

  final List<CoordUnit> units;

  @override
  State<UnitsView> createState() => _UnitsViewState();
}

class _UnitsViewState extends State<UnitsView> {
  var _showAll = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    if (widget.units.isEmpty) {
      return _emptyNote(context, 'No units in this program yet.');
    }
    final today = DateTime.now().weekday;
    final shown =
        _showAll ? widget.units : widget.units.where((u) => u.dayOfWeek == today).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              _showAll ? 'All units' : 'Today (${kDays[today]})',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 12,
                color: scheme.primary,
              ),
            ),
            const Spacer(),
            TextButton(
              onPressed: () => setState(() => _showAll = !_showAll),
              child: Text(
                _showAll ? 'Show today only' : 'Show all units',
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
        if (shown.isEmpty)
          _emptyNote(
            context,
            'No units scheduled for today. Tap "Show all units" to see the '
            'full program.',
          )
        else
          for (final u in shown)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        u.name,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                      Text(
                        '${u.unitId} · '
                        '${u.start.isNotEmpty ? '${_dayLabel(u.dayOfWeek)} ${u.start}' : '—'}'
                        '${u.lecturers.isNotEmpty ? ' · ${u.lecturers}' : ''}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(),
              ],
            ),
      ],
    );
  }

  String _dayLabel(int dow) =>
      dow >= 1 && dow <= 7 ? '${kDays[dow]} ' : '';
}

Widget _emptyNote(BuildContext context, String msg) => Padding(
      padding: const EdgeInsets.all(20),
      child: Text(
        msg,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontSize: 13,
        ),
      ),
    );