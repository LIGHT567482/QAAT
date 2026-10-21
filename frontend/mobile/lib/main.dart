import 'package:flutter/material.dart';

import 'core/api/api_client.dart';
import 'core/auth/auth_repository.dart';
import 'core/brand/brand.g.dart';
import 'features/auth/login_screen.dart';
import 'features/lecturer/lecturer_home.dart';
import 'features/student/student_home.dart';

void main() {
  runApp(const QaatApp());
}

class QaatApp extends StatefulWidget {
  const QaatApp({super.key});

  @override
  State<QaatApp> createState() => _QaatAppState();
}

class _QaatAppState extends State<QaatApp> {
  final ApiClient _api = ApiClient();
  late final AuthRepository _auth = AuthRepository(_api);

  User? _user;
  bool _restoring = true;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    final user = await _auth.restoreSession();
    if (!mounted) return;
    setState(() {
      _user = user;
      _restoring = false;
    });
  }

  void _signedIn(User user) => setState(() => _user = user);

  Future<void> _signedOut() async {
    await _auth.clear();
    if (!mounted) return;
    setState(() => _user = null);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: QaatBrand.appName,
      debugShowCheckedModeBanner: false,
      // Every colour here comes from brand.json — see core/brand/brand.g.dart.
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: QaatBrand.brandColor,
          primary: QaatBrand.brandColor,
          surface: QaatBrand.backgroundColor,
        ),
        scaffoldBackgroundColor: QaatBrand.backgroundColor,
        appBarTheme: const AppBarTheme(
          backgroundColor: QaatBrand.headerColor,
          foregroundColor: QaatBrand.textColorDark,
          elevation: 0,
        ),
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: QaatBrand.sidebarColor,
          indicatorColor: QaatBrand.brandColor.withAlpha(64),
          elevation: 0,
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: QaatBrand.brandColor,
            foregroundColor: QaatBrand.textColorDark,
          ),
        ),
        cardTheme: const CardThemeData(
          elevation: 0,
          color: Color(0xFFFFFFFF),
        ),
      ),
      home: Builder(
        builder: (context) {
          if (_restoring) {
            return const Scaffold(body: Center(child: CircularProgressIndicator()));
          }
          final user = _user;
          if (user == null) {
            return LoginScreen(auth: _auth, onSignedIn: _signedIn);
          }
          // Role routing: lecturers (and kiu_admin with attendance access)
          // get the lecturer surface; everyone else gets the student surface.
          if (user.isLecturer && !user.isStudent) {
            return LecturerHome(auth: _auth, user: user, onSignedOut: _signedOut);
          }
          return StudentHome(auth: _auth, user: user, onSignedOut: _signedOut);
        },
      ),
    );
  }
}
