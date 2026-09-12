import 'package:flutter/material.dart';

import '../net/auth_client.dart';
import '../net/branding.dart';
import '../net/portal_client.dart';
import '../net/session_store.dart';
import '../patrol/notification_client.dart';
import 'brand_widgets.dart';
import 'patrol/patrol_alerts_tab.dart';

/// The lecturer's and student's in-app dashboards.
///
/// Both land on a hub like the coordinator's: their name, their inbox (the same
/// cross-role alerts every role reads) and their own record — the lecturer's
/// teaching roster with per-unit attendance, the student's own attendance and
/// exam eligibility. Each loads over the shared gateway and, offline, shows the
/// last data it brought down with the offline banner that already sits over the
/// app; there is deliberately no credential prompt here — a saved session boots
/// straight back onto this screen.
class RoleHubShell extends StatelessWidget {
  const RoleHubShell({
    super.key,
    required this.result,
    required this.roleLabel,
    required this.body,
  });

  final LoginResult result;
  final String roleLabel;
  final Widget body;

  @override
  Widget build(BuildContext context) {
    final branding = BrandingState.current.value;
    final navColor = navBarColor(branding);
    final onNav = navColor == null ? null : onNavColor(navColor);
    final bg = appBackgroundColor(branding);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: navColor,
        foregroundColor: onNav,
        title: BrandHeader(branding: branding),
        leading: IconButton(
          icon: const Icon(Icons.logout),
          tooltip: 'Sign out',
          color: onNav,
          onPressed: () async {
            await SessionStore.clear();
            if (context.mounted) {
              Navigator.of(context)
                  .pushNamedAndRemoveUntil('/login', (_) => false);
            }
          },
        ),
      ),
      body: Column(
        children: [
          const OfflineBanner(),
          Expanded(child: Stack(children: [body, const BrandWatermark()])),
        ],
      ),
      backgroundColor: bg,
    );
  }
}

class LecturerDashboard extends StatefulWidget {
  const LecturerDashboard({super.key, required this.result});

  final LoginResult result;

  @override
  State<LecturerDashboard> createState() => _LecturerDashboardState();
}

class _LecturerDashboardState extends State<LecturerDashboard> {
  static const _client = PortalClient();
  static const _notif = NotificationClient();

  List<LecturerUnit>? _units; // null = loading
  List<Notif>? _inbox;
  String? _error;

  LoginResult get _r => widget.result;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final units = await _client.lecturerOverview(_r.token, _r.staffId);
    final inbox = await _notif.inbox(_r.token);
    if (!mounted) return;
    setState(() {
      _units = units;
      _inbox = inbox;
      _error = null;
    });
  }

  Future<void> _openUnit(LecturerUnit u) async {
    final att = await _client.lecturerUnitAttendance(
      _r.token,
      _r.staffId,
      u.unitId,
    );
    if (!mounted) return;
    if (att == null) {
      setState(
        () => _error =
            'Could not load the attendance record — check your connection.',
      );
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _UnitAttendanceScreen(unit: u, attendance: att),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return RoleHubShell(
      result: _r,
      roleLabel: 'Lecturer',
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            _r.fullName.isNotEmpty ? '${_r.fullName}, Lecturer' : 'Lecturer',
            style: theme.textTheme.headlineSmall,
          ),
          Text(
            'Staff ID: ${_r.staffId.isNotEmpty ? _r.staffId : '—'}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _error!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          const SizedBox(height: 12),
          _SectionTitle(
            title: 'Your teaching units',
            action: IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Refresh',
              onPressed: _load,
            ),
          ),
          Text(
            'The attendance record for each unit is kept as it was recorded — '
            'by the coordinator and by the QA monitor, never merged.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          switch (_units) {
            null => const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Center(child: CircularProgressIndicator()),
            ),
            [] => Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                _r.staffId.isEmpty
                    ? 'Your account has no staff ID on file, so nothing can be shown.'
                    : 'No units are assigned to you yet. This is read from the teaching roster.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            _ => Column(
              children: [
                for (final u in _units!)
                  Card(
                    child: ListTile(
                      title: Text(u.name.isNotEmpty ? u.name : u.unitId),
                      subtitle: Text(
                        [
                          u.unitId,
                          if (u.courseName.isNotEmpty) u.courseName,
                          'Yr ${u.year} · Sem ${u.semester}',
                        ].join(' · '),
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _openUnit(u),
                    ),
                  ),
              ],
            ),
          },
          const SizedBox(height: 16),
          _SectionTitle(title: 'Notifications'),
          const SizedBox(height: 4),
          ..._inboxCells(theme),
        ],
      ),
    );
  }

  List<Widget> _inboxCells(ThemeData theme) {
    final inbox = _inbox;
    if (inbox == null) {
      return const [
        Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    }
    if (inbox.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(
            'No notifications yet.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ];
    }
    return [
      for (final n in inbox.take(6))
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: NotificationCard(
            notif: n,
            onOpen: () => NotificationClient().markRead(_r.token, n.id),
            onDismiss: () async {
              await NotificationClient().dismiss(_r.token, n.id);
              _load();
            },
          ),
        ),
    ];
  }
}

class _UnitAttendanceScreen extends StatefulWidget {
  const _UnitAttendanceScreen({required this.unit, required this.attendance});

  final LecturerUnit unit;
  final UnitAttendance attendance;

  @override
  State<_UnitAttendanceScreen> createState() => _UnitAttendanceScreenState();
}

class _UnitAttendanceScreenState extends State<_UnitAttendanceScreen> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final a = widget.attendance;
    final onSurface = theme.colorScheme.onSurfaceVariant;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.unit.name.isNotEmpty ? widget.unit.name : widget.unit.unitId,
        ),
      ),
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                [
                  widget.unit.unitId,
                  widget.unit.courseName,
                ].where((s) => s.isNotEmpty).join(' · '),
                style: theme.textTheme.bodySmall?.copyWith(color: onSurface),
              ),
              const SizedBox(height: 12),
              Text(
                'Sessions: ${a.sessions.length}',
                style: theme.textTheme.titleSmall,
              ),
              if (a.sessions.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    'No sessions held yet for this unit.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: onSurface,
                    ),
                  ),
                ),
              for (final s in a.sessions)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.calendar_today, size: 18),
                  title: Text(s.date),
                  subtitle: s.coordinator.isNotEmpty
                      ? Text('Coordinator: ${s.coordinator}')
                      : null,
                ),
              const SizedBox(height: 12),
              Text(
                'Attendance roll — ${a.students.length} students',
                style: theme.textTheme.titleSmall,
              ),
              for (final st in a.students.take(50))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Expanded(child: Text(st.fullName)),
                      if (a.sessions.isNotEmpty)
                        Text(
                          '${st.present.where((p) => p).length}/${a.sessions.length}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color:
                                st.present.isNotEmpty &&
                                    st.present.every((p) => p)
                                ? theme.colorScheme.primary
                                : onSurface,
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
          const BrandWatermark(),
        ],
      ),
    );
  }
}

class StudentDashboard extends StatefulWidget {
  const StudentDashboard({super.key, required this.result});

  final LoginResult result;

  @override
  State<StudentDashboard> createState() => _StudentDashboardState();
}

class _StudentDashboardState extends State<StudentDashboard> {
  static const _client = PortalClient();
  static const _notif = NotificationClient();

  StudentProgress? _progress;
  List<Notif>? _inbox;
  String? _error;

  LoginResult get _r => widget.result;
  String get _regNo =>
      _r.registrationNo.isNotEmpty ? _r.registrationNo : _r.studentId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final progress = await _client.studentProgress(_r.token, _regNo);
    final inbox = await _notif.inbox(_r.token);
    if (!mounted) return;
    setState(() {
      _progress = progress;
      _inbox = inbox;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = _progress;
    return RoleHubShell(
      result: _r,
      roleLabel: 'Student',
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            p?.fullName.isNotEmpty == true
                ? '${p!.fullName}, Student'
                : 'Student',
            style: theme.textTheme.headlineSmall,
          ),
          Text(
            'Reg no: ${_regNo.isNotEmpty ? _regNo : '—'}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _error!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          const SizedBox(height: 12),
          _SectionTitle(
            title: 'Your attendance',
            action: IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Refresh',
              onPressed: _load,
            ),
          ),
          Text(
            p == null
                ? 'Loading your record…'
                : '${p.academicYear.isNotEmpty ? p.academicYear : ''}'
                      '${p.semester > 0 ? ' · Semester ${p.semester}' : ''}'
                      '${p.department.isNotEmpty ? ' · ${p.department}' : ''}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          if (p == null && _error == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (p == null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'Your attendance record could not be loaded — check your connection. '
                'Everything else below still works.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            )
          else if (p.units.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'No attendance summary is on file yet.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            )
          else
            Column(
              children: [
                for (final u in p.units)
                  Card(
                    child: ListTile(
                      title: Text(
                        u.unitName.isNotEmpty ? u.unitName : u.unitId,
                      ),
                      subtitle: Text(
                        '${u.sessionsAttended}/${u.sessionsHeld} sessions · '
                        '${u.attendancePct.toStringAsFixed(1)}%',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: u.status == 'EXAM_INELIGIBLE'
                              ? theme.colorScheme.error
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      trailing: u.status == 'EXAM_INELIGIBLE'
                          ? Icon(
                              Icons.error_outline,
                              color: theme.colorScheme.error,
                            )
                          : const Icon(Icons.check_circle_outline),
                    ),
                  ),
              ],
            ),
          const SizedBox(height: 16),
          _SectionTitle(title: 'Notifications'),
          const SizedBox(height: 4),
          ..._inboxCells(theme),
        ],
      ),
    );
  }

  List<Widget> _inboxCells(ThemeData theme) {
    final inbox = _inbox;
    if (inbox == null) {
      return const [
        Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    }
    if (inbox.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(
            'No notifications yet.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ];
    }
    return [
      for (final n in inbox.take(6))
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: NotificationCard(
            notif: n,
            onOpen: () => NotificationClient().markRead(_r.token, n.id),
            onDismiss: () async {
              await NotificationClient().dismiss(_r.token, n.id);
              _load();
            },
          ),
        ),
    ];
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, this.action});
  final String title;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: Theme.of(context).textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.bold),
          ),
        ),
        ?action,
      ],
    );
  }
}
