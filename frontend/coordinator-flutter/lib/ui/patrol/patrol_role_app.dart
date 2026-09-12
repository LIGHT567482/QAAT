import 'package:flutter/material.dart';

import '../../net/auth_client.dart';
import '../../net/branding.dart';
import '../../net/connectivity.dart';
import '../../patrol/fingerprint.dart';
import '../../patrol/notification_client.dart';
import '../../patrol/patrol_client.dart';
import '../../patrol/patrol_store.dart';
import '../brand_widgets.dart';
import 'office_round_tab.dart';
import 'patrol_alerts_tab.dart';
import 'patrol_profile_tab.dart';
import 'patrol_round_tab.dart';
import 'pin_gate.dart';
import 'sign_out_button.dart';
import 'sync_pending.dart';

/// The QA MONITOR experience, inside the one KIU QAAT app — a faithful port of the
/// native `PatrolRoleApp`.
///
/// The separation between this role and every other is enforced in three places:
///
///  1. **Role routing** — [HomeScreen] sends `QA_PATROLLER` here and nowhere else.
///     There is no path from this screen into the coordinator hub, the lecturer
///     roster, or a student's record.
///  2. **Handset binding** — the round is gated on the device gate below. The
///     gateway ties the monitor's account to this handset and refuses monitor calls
///     from any other, so a token lifted off another phone buys an attacker nothing.
///  3. **A PIN** — [PatrolPinGate], the second page after sign-in. The binding
///     proves WHICH phone; the PIN proves WHO is holding it.
class PatrolRoleApp extends StatefulWidget {
  const PatrolRoleApp({super.key, required this.result});

  final LoginResult result;

  @override
  State<PatrolRoleApp> createState() => _PatrolRoleAppState();
}

enum _GateState { checking, allowed, refused, offline }

class _PatrolRoleAppState extends State<PatrolRoleApp> {
  _GateState _gate = _GateState.checking;
  String? _gateMessage;
  int _tab = 0;
  int _reloadKey = 0;
  int _unread = 0;

  LoginResult get _result => widget.result;
  String get _token => _result.token;
  String get _name => _result.fullName;
  String get _staffId => _result.staffId;

  @override
  void initState() {
    super.initState();
    _claim();
    _refreshUnread();
    onOnlineBeats.add(_autoSyncBeat);
  }

  @override
  void dispose() {
    onOnlineBeats.remove(_autoSyncBeat);
    super.dispose();
  }

  /// The auto-sync beat. The monitor probes reachability once every ~25s; each
  /// ONLINE probe calls this, draining whatever the round has queued while nobody
  /// was pressing the refresh arrow. A freshly-restored connection (offline → online)
  /// also reloads the tabs' cached data, so a corridor record is both pushed AND
  /// followed by a refresh that shows it synced.
  Future<void> _autoSyncBeat(bool wasOffline) async {
    if (!mounted) return;
    if (wasOffline) {
      setState(() => _reloadKey++);
      _refreshUnread();
      return;
    }
    final pending = await patrolStore.pendingSyncCount();
    if (!mounted || pending == 0) return;
    await syncPending(_token);
    await syncPendingOffice(_token);
    if (mounted) setState(() => _reloadKey++);
  }

  /// Device first, then person. Checking the handset before asking for the PIN means
  /// a monitor on the wrong phone is told so immediately, rather than typing a PIN
  /// that was never going to be accepted.
  Future<void> _claim() async {
    setState(() {
      _gate = _GateState.checking;
      _gateMessage = null;
    });
    try {
      final msg = await PatrolClient().bindDevice(
        _token,
        await DeviceFingerprint.get(),
      );
      if (!mounted) return;
      setState(() {
        if (msg == null) {
          _gate = _GateState.allowed;
        } else {
          _gate = _GateState.refused;
          _gateMessage = msg;
        }
      });
    } on Object {
      if (!mounted) return;
      // Offline is deliberately NOT a refusal: a monitor walking a corridor with no
      // signal must still be able to tick a room. The binding was proved when they
      // signed in, and nothing they record offline reaches the server until a sync —
      // which is itself bound-checked.
      setState(() {
        _gate = _GateState.offline;
        _gateMessage =
            'Offline — this phone could not be re-checked. Your ticks are saved '
            'and will sync later.';
      });
    }
  }

  Future<void> _refreshUnread() async {
    final u = await const NotificationClient().unread(_token);
    if (mounted) setState(() => _unread = u);
  }

  void _refresh() {
    setState(() => _reloadKey++);
    _refreshUnread();
  }

  @override
  Widget build(BuildContext context) {
    switch (_gate) {
      case _GateState.checking:
        return _gateScreen(
          context,
          body: const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 12),
                Text('Checking this phone…'),
              ],
            ),
          ),
        );
      case _GateState.refused:
        return _lockedScreen(
          _gateMessage ??
              'This phone is not the one registered for your monitor account.',
        );
      case _GateState.offline:
        return _offlineScreen(context);
      case _GateState.allowed:
        return PatrolPinGate(
          token: _token,
          buildRound: (_) => _roundScaffold(context),
        );
    }
  }

  Widget _gateScreen(BuildContext context, {required Widget body}) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: SafeArea(
        child: Padding(padding: const EdgeInsets.all(28), child: body),
      ),
    );
  }

  /// Dead end for a handset the server will not accept. The only way out is signing
  /// out.
  Widget _lockedScreen(String message) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Center(
                    child: Text('🔒', style: TextStyle(fontSize: 40)),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Monitoring is locked on this phone',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    message,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'A monitor account works on one registered handset. If you have '
                    'changed phones, ask an administrator to release your device '
                    'binding.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 24),
                  const SignOutButton(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Offline banner above the (still functional) round.
  Widget _offlineScreen(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Material(
          color: theme.colorScheme.errorContainer,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _gateMessage ?? '',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onErrorContainer,
                    ),
                  ),
                ),
                TextButton(onPressed: _claim, child: const Text('Retry')),
              ],
            ),
          ),
        ),
        Expanded(
          child: PatrolPinGate(
            token: _token,
            buildRound: (_) => _roundScaffold(context),
          ),
        ),
      ],
    );
  }

  Widget _roundScaffold(BuildContext context) {
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
          IconButton(
            icon: const Icon(Icons.sync),
            tooltip: 'Refresh',
            color: onNav,
            onPressed: _refresh,
          ),
        ],
      ),
      bottomNavigationBar: _tabs(context, onNav, navColor),
      body: Column(
        children: [
          // The shared reachability strip — everywhere in the app, one probe.
          const OfflineBanner(),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: _tabBody(context),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tabs(BuildContext context, Color? onNav, Color? navColor) {
    final theme = Theme.of(context);
    return NavigationBar(
      backgroundColor: navColor ?? theme.colorScheme.surfaceContainerHighest,
      indicatorColor: (onNav ?? theme.colorScheme.primary).withValues(
        alpha: 0.18,
      ),
      selectedIndex: _tab,
      onDestinationSelected: (i) {
        setState(() => _tab = i);
        _refreshUnread();
      },
      destinations: [
        const NavigationDestination(
          icon: Icon(Icons.door_sliding),
          label: 'Rooms',
        ),
        const NavigationDestination(
          icon: Icon(Icons.business),
          label: 'Offices',
        ),
        NavigationDestination(
          icon: _unread > 0
              ? Badge(
                  label: Text('$_unread'),
                  child: const Icon(Icons.notifications),
                )
              : const Icon(Icons.notifications),
          label: 'Alerts',
        ),
        const NavigationDestination(icon: Icon(Icons.person), label: 'Profile'),
      ],
    );
  }

  Widget _tabBody(BuildContext context) {
    // An index outside the four is a bug; landing on Profile is the wrong recovery —
    // the round is what the monitor opened the app to do.
    switch (_tab) {
      case 1:
        return OfficeRoundTab(
          token: _token,
          reloadKey: _reloadKey,
          name: _name,
          staffId: _staffId,
        );
      case 2:
        return PatrolAlertsTab(token: _token);
      case 3:
        return PatrolProfileTab(
          token: _token,
          fullName: _name,
          staffId: _staffId,
        );
      default:
        return PatrolRoundTab(
          token: _token,
          reloadKey: _reloadKey,
          name: _name,
          staffId: _staffId,
        );
    }
  }
}
