import 'package:flutter/material.dart';

import '../../../core/api/api_client.dart';
import '../../../core/auth/auth_repository.dart';
import 'attendance_view.dart';

/// Student surface. Per spec doc 07 §"students have no dashboard" — the nav
/// is Attendance · Notices · Profile. Attendance renders the merge-slot
/// pending state until the engine lands.
class StudentHome extends StatefulWidget {
  const StudentHome({super.key, required this.auth, required this.user, required this.onSignedOut});

  final AuthRepository auth;
  final User user;
  final VoidCallback onSignedOut;

  @override
  State<StudentHome> createState() => _StudentHomeState();
}

class _StudentHomeState extends State<StudentHome> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final pages = [
      AttendanceView(api: widget.auth.api, group: 'student'),
      const _NoticesView(),
      _ProfileView(user: widget.user, onSignedOut: widget.onSignedOut),
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
          NavigationDestination(icon: Icon(Icons.fact_check_outlined), label: 'Attendance'),
          NavigationDestination(icon: Icon(Icons.notifications_outlined), label: 'Notices'),
          NavigationDestination(icon: Icon(Icons.person_outline), label: 'Profile'),
        ],
      ),
    );
  }
}

class _NoticesView extends StatelessWidget {
  const _NoticesView();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Text('Notices will load once the notices API is wired.'),
      ),
    );
  }
}

class _ProfileView extends StatelessWidget {
  const _ProfileView({required this.user, required this.onSignedOut});
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
          subtitle: Text(user.email),
        ),
        ListTile(
          leading: const Icon(Icons.badge_outlined),
          title: const Text('Registration number'),
          trailing: Text(user.registrationNumber ?? '—'),
        ),
        ListTile(
          leading: const Icon(Icons.verified_outlined),
          title: const Text('Email verified'),
          trailing: Text(user.emailVerified ? 'Yes' : 'No'),
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
