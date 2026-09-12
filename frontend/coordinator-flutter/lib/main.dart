import 'package:flutter/material.dart';

import 'net/branding.dart';
import 'net/connectivity.dart';
import 'net/session_store.dart';
import 'ui/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Apply the bundled institution branding instantly (offline-safe), so even the
  // login screen greets the tenant in its own colours before the backend answers.
  await BrandingState.loadDefault();
  // A saved session means the app boots straight into the signed-in hub — a
  // monitor or a lecturer does not re-type credentials on every launch.
  final session = await SessionStore.load();
  AppRoutes.initialLogin = session;
  runApp(QaatCoordinatorApp(hasSession: session != null));
  // The one reachability probe on the phone, on a beat: it drives the offline
  // banner everywhere and the patroller app's background queue drain.
  NetMonitor.start();
}

/// Boot state handed to the app's own renderer.
class QaatCoordinatorApp extends StatelessWidget {
  const QaatCoordinatorApp({super.key, this.hasSession = false});

  /// Whether this launch woke up signed in; '/' then routes to the hub
  /// (via [AppRoutes.initialLogin]) instead of the login screen.
  final bool hasSession;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Branding?>(
      valueListenable: BrandingState.current,
      builder: (context, branding, _) => MaterialApp(
        title: 'KIU QAAT',
        theme: ThemeData(
          colorScheme: brandedColorScheme(branding),
          useMaterial3: true,
        ),
        initialRoute: hasSession ? '/home' : '/login',
        onGenerateRoute: AppRoutes.onGenerateRoute,
      ),
    );
  }
}
