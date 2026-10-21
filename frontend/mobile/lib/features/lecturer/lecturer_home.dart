import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../core/api/api_client.dart';
import '../../../core/auth/auth_repository.dart';
import '../student/attendance_view.dart';

/// Lecturer surface (spec doc 07). Dashboard · Attendance · Notices · Settings.
/// Session start/end live behind the attendance merge slot until the engine
/// lands — those controls surface the pending state instead of firing.
class LecturerHome extends StatefulWidget {
  const LecturerHome({super.key, required this.auth, required this.user, required this.onSignedOut});

  final AuthRepository auth;
  final User user;
  final VoidCallback onSignedOut;

  @override
  State<LecturerHome> createState() => _LecturerHomeState();
}

class _LecturerHomeState extends State<LecturerHome> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final pages = [
      _DashboardView(api: widget.auth.api),
      AttendanceView(api: widget.auth.api, group: 'lecturer'),
      const _NoticesView(),
      _SettingsView(user: widget.user, onSignedOut: widget.onSignedOut),
    ];
    return Scaffold(
      appBar: AppBar(
        title: Text('QAAT — ${widget.user.role}'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Sign out',
            onPressed: widget.onSignedOut,
          ),
        ],
      ),
      body: pages[_tab],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.dashboard_outlined), label: 'Dashboard'),
          NavigationDestination(icon: Icon(Icons.fact_check_outlined), label: 'Attendance'),
          NavigationDestination(icon: Icon(Icons.notifications_outlined), label: 'Notices'),
          NavigationDestination(icon: Icon(Icons.settings_outlined), label: 'Settings'),
        ],
      ),
    );
  }
}

class _DashboardView extends StatelessWidget {
  const _DashboardView({required this.api});
  final ApiClient api;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, dynamic>>(
      future: api.lecturerDashboard(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          final e = snap.error;
          if (e is ApiException && e.isPendingMerge) {
            return const _PendingCard();
          }
          return Center(child: Text('$e'));
        }
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const _PendingCard(),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'Summary:\n${const JsonEncoder.withIndent('  ').convert(snap.data ?? {})}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _PendingCard extends StatelessWidget {
  const _PendingCard();
  @override
  Widget build(BuildContext context) {
    return Card(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: const Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          children: [
            Icon(Icons.hourglass_top_outlined, size: 40),
            SizedBox(height: 8),
            Text('Attendance engine pending merge',
                textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.w600)),
            SizedBox(height: 4),
            Text(
              'Start session, join code and live roll appear once the attendance '
              'logic merges in.\ndocs/qaat-spec/06-attendance-module.md',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _NoticesView extends StatelessWidget {
  const _NoticesView();
  @override
  Widget build(BuildContext context) {
    return const Center(child: Text('Notices — coming online with the notices API.'));
  }
}

class _SettingsView extends StatelessWidget {
  const _SettingsView({required this.user, required this.onSignedOut});
  final User user;
  final VoidCallback onSignedOut;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        ListTile(
          leading: const CircleAvatar(child: Icon(Icons.person)),
          title: Text(user.fullName.isNotEmpty ? user.fullName : user.email),
          subtitle: Text(user.role),
        ),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.logout),
          title: const Text('Sign out'),
          onTap: onSignedOut,
        ),
      ],
    );
  }
}
