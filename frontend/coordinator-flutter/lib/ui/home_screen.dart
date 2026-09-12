import 'package:flutter/material.dart';

import '../net/auth_client.dart';
import '../net/branding.dart';
import '../net/session_store.dart';
import 'brand_widgets.dart';
import 'change_password_screen.dart';
import 'coordinator/coordinator_hub.dart';
import 'dashboards.dart';
import 'login_screen.dart';
import 'patrol/patrol_role_app.dart';

/// The hub after sign-in, dispatched by role. Mirrors the Android app's split:
/// a coordinator lands on their attendance/hub screens, a QA patroller on the
/// monitor round, and lecturers and students on their own dashboards. Routing is
/// by `role` returned from app-login.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.result});

  final LoginResult result;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _passwordChanged = false;

  @override
  Widget build(BuildContext context) {
    final r = widget.result;
    if (r.forcePasswordChange && !_passwordChanged) {
      return ChangePasswordScreen(
        auth: AuthClient(),
        token: r.token,
        onChanged: () => setState(() => _passwordChanged = true),
      );
    }
    if (r.role == 'COORDINATOR') return CoordinatorHub(result: r);
    // The QA patroller is the unified app's second role: the handset-claim, PIN-gated
    // monitor round. No path exists from it into the coordinator hub (and vice versa).
    if (r.role == 'QA_PATROLLER') return PatrolRoleApp(result: r);
    if (r.role == 'LECTURER') return LecturerDashboard(result: r);
    if (r.role == 'STUDENT') return StudentDashboard(result: r);
    return _OtherRolePlaceholder(result: r);
  }
}

class _OtherRolePlaceholder extends StatelessWidget {
  const _OtherRolePlaceholder({required this.result});

  final LoginResult result;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final branding = BrandingState.current.value;
    final navColor = navBarColor(branding);
    final onNav = navColor == null ? null : onNavColor(navColor);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: navColor,
        foregroundColor: onNav,
        title: BrandHeader(branding: branding),
        leading: IconButton(
          icon: Icon(Icons.logout),
          tooltip: 'Sign out',
          color: onNav,
          onPressed: () =>
              Navigator.of(context)
                  .pushNamedAndRemoveUntil('/login', (_) => false),
        ),
      ),
      body: Stack(
        children: [
          Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const BrandLogo(branding: null, size: 72),
                  const SizedBox(height: 16),
                  Text(
                    'Signed in as ${result.displayName(result.role)}',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'This version of KIU QAAT runs as an internal Quality Assurance '
                    'system. ${result.role} works on the QAAT web dashboard, not on '
                    'the phone app — open the dashboard in your browser and sign in '
                    'with the same details.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const BrandWatermark(),
        ],
      ),
    );
  }
}

/// Route setup shared by tests and [main]: '/' is the login, '/home' the
/// role-dispatched hub. [initialLogin] is the session restored at boot from
/// [SessionStore], used when '/home' is hit without explicit arguments — the
/// offline-tolerant path that lands a returning user straight back on their hub.
class AppRoutes {
  const AppRoutes._();

  static LoginResult? initialLogin;

  static Route<dynamic>? onGenerateRoute(RouteSettings settings) {
    switch (settings.name) {
      case '/login':
        return MaterialPageRoute<void>(
          builder: (_) => const LoginScreen(),
          settings: settings,
        );
      case '/home':
        final result = settings.arguments as LoginResult? ?? initialLogin;
        if (result == null) {
          return MaterialPageRoute<void>(
            builder: (_) => const LoginScreen(),
            settings: settings,
          );
        }
        return MaterialPageRoute<void>(
          builder: (_) => HomeScreen(result: result),
          settings: settings,
        );
      default:
        return null;
    }
  }
}
