import 'package:flutter/material.dart';

import '../../net/auth_client.dart';
import '../../net/branding.dart';
import '../../net/session_store.dart';
import '../brand_widgets.dart';
import '../change_password_screen.dart';
import 'absentees_tab.dart';
import 'app_state.dart';
import 'alerts_tab.dart';
import 'home_tab.dart';
import 'session_tab.dart';
import 'sync_tab.dart';
import 'trends_tab.dart';

/// The coordinator's hub — a faithful port of the native `CoordinatorApp` shell:
/// a branded top bar with Refresh + Profile, and six bottom tabs (Home, Attendance,
/// Absentees, Trends, Alerts, Sync). Tabs keep their own state in an [IndexedStack]
/// so switching never reloads a screen that was already loaded.
class CoordinatorHub extends StatefulWidget {
  const CoordinatorHub({super.key, required this.result});

  final LoginResult result;

  @override
  State<CoordinatorHub> createState() => _CoordinatorHubState();
}

class _CoordinatorHubState extends State<CoordinatorHub> {
  int _tab = 0;

  LoginResult get _r => widget.result;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    if (_r.token.isEmpty) return;
    CoordinatorState.refreshing.value = true;
    CoordinatorState.refreshTick.value++;
    // Pull the overview + active sessions and give the tabs a beat to start their
    // own reload, then release the ⟳ button; each tab shows its own loading state.
    await Future.wait([
      CoordinatorState.refreshAll(_r),
      Future<void>.delayed(const Duration(milliseconds: 350)),
    ]);
    CoordinatorState.refreshing.value = false;
  }

  Future<void> _signOut() async {
    final sessionId = CoordinatorState.activeSessionId;
    if (sessionId != null && sessionId.isNotEmpty) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('End the session first'),
          content: const Text(
            'A session is still open. End it first — that seals the attendance and '
            'uploads it. Signing out now would leave the room\'s check-ins stranded '
            'on this phone.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      if (proceed != true) return;
    }
    await SessionStore.clear();
    CoordinatorState.clearOpenRegister();
    if (mounted) {
      Navigator.of(context).pushNamedAndRemoveUntil('/login', (_) => false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final branding = BrandingState.current.value;
    final navColor = navBarColor(branding);
    final onNav = navColor == null ? null : onNavColor(navColor);
    final bg = appBackgroundColor(branding);
    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: navColor,
        foregroundColor: onNav,
        title: BrandHeader(branding: branding),
        actions: [
          ValueListenableBuilder<bool>(
            valueListenable: CoordinatorState.refreshing,
            builder: (context, refreshing, _) => IconButton(
              icon: refreshing
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
              tooltip: refreshing ? 'Refreshing' : 'Refresh',
              color: onNav,
              onPressed: refreshing ? null : _refresh,
            ),
          ),
          _ProfileMenu(
            result: _r,
            onSignOut: _signOut,
            onChangedPassword: () {
              if (mounted) {
                setState(() {});
              }
            },
          ),
        ],
      ),
      bottomNavigationBar: _NavigationBar(
        selected: _tab,
        onSelect: (i) => setState(() => _tab = i),
        navColor: navColor,
        onNav: onNav,
      ),
      body: Column(
        children: [
          const OfflineBanner(),
          Expanded(
            child: Stack(
              children: [
                IndexedStack(
                  index: _tab,
                  children: [
                    CoordinatorHomeTab(result: _r),
                    CoordinatorSessionTab(result: _r),
                    AbsenteesTab(result: _r),
                    TrendsTab(result: _r),
                    CoordinatorAlertsTab(result: _r),
                    SyncAuditTab(result: _r),
                  ],
                ),
                const BrandWatermark(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The six bottom destinations in the native app's exact order.
class _NavigationBar extends StatelessWidget {
  const _NavigationBar({
    required this.selected,
    required this.onSelect,
    required this.navColor,
    required this.onNav,
  });

  final int selected;
  final ValueChanged<int> onSelect;
  final Color? navColor;
  final Color? onNav;

  static const _items = [
    (Icons.home_outlined, Icons.home, 'Home'),
    (Icons.play_arrow_outlined, Icons.play_arrow, 'Attendance'),
    (Icons.warning_amber_outlined, Icons.warning_amber_rounded, 'Absentees'),
    (Icons.show_chart, Icons.show_chart, 'Trends'),
    (Icons.notifications_outlined, Icons.notifications, 'Alerts'),
    (Icons.sync, Icons.sync, 'Sync'),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return NavigationBar(
      backgroundColor: navColor ?? scheme.surface,
      selectedIndex: selected,
      onDestinationSelected: onSelect,
      indicatorColor: onNav?.withValues(alpha: 0.18),
      destinations: [
        for (var i = 0; i < _items.length; i++)
          NavigationDestination(
            icon: Icon(_items[i].$1, color: onNav ?? scheme.onSurfaceVariant),
            selectedIcon: Icon(_items[i].$2, color: onNav ?? scheme.primary),
            label: _items[i].$3,
          ),
      ],
    );
  }
}

/// The top-end Profile popup: identity then the two actions every role shares.
class _ProfileMenu extends StatelessWidget {
  const _ProfileMenu({
    required this.result,
    required this.onSignOut,
    required this.onChangedPassword,
  });

  final LoginResult result;
  final VoidCallback onSignOut;
  final VoidCallback onChangedPassword;

  @override
  Widget build(BuildContext context) {
    final titled = [result.title, result.fullName]
        .where((s) => s.isNotEmpty)
        .join(' ');
    return PopupMenuButton<_ProfileAction>(
      icon: const Icon(Icons.menu),
      tooltip: 'Profile',
      itemBuilder: (context) => [
        PopupMenuItem<_ProfileAction>(
          enabled: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                titled.isNotEmpty ? titled : 'Profile',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              if (result.staffId.isNotEmpty)
                Text(
                  'Staff ID: ${result.staffId}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              Text(
                result.role,
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ],
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: _ProfileAction.changePassword,
          child: Text('🔑  Change password'),
        ),
        const PopupMenuItem(
          value: _ProfileAction.signOut,
          child: Text(
            '⎋  Sign out',
            style: TextStyle(color: Colors.redAccent),
          ),
        ),
      ],
      onSelected: (action) async {
        switch (action) {
          case _ProfileAction.changePassword:
            await Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => ChangePasswordScreen(
                  auth: AuthClient(),
                  token: result.token,
                  onChanged: onChangedPassword,
                ),
              ),
            );
          case _ProfileAction.signOut:
            onSignOut();
        }
      },
    );
  }
}

enum _ProfileAction { changePassword, signOut }