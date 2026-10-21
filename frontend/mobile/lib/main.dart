import 'package:flutter/material.dart';

import 'core/api/api_client.dart';
import 'core/auth/auth_repository.dart';
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
      title: 'QAAT',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1A56DB)),
        useMaterial3: true,
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
