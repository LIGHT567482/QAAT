import 'package:flutter_test/flutter_test.dart';
import 'package:qaat/core/api/api_client.dart';

void main() {
  group('ApiException merge-slot detection', () {
    test('501 is pending merge', () {
      final e = ApiException(501, 'attendance logic pending merge');
      expect(e.isPendingMerge, isTrue);
      expect(e.isUnauthorized, isFalse);
    });

    test('401 is unauthorized', () {
      final e = ApiException(401, 'Authentication credentials were not provided.');
      expect(e.isUnauthorized, isTrue);
      expect(e.isPendingMerge, isFalse);
    });

    test('500 is neither', () {
      final e = ApiException(500, 'boom');
      expect(e.isPendingMerge, isFalse);
      expect(e.isUnauthorized, isFalse);
    });
  });

  group('User role flags (spec doc 05 §1)', () {
    User u(String role) => User(
          id: 'x',
          email: 'a@b.c',
          fullName: 'N',
          role: role,
          emailVerified: true,
          registrationNumber: null,
        );

    test('student is neither lecturer nor staff', () {
      final s = u('student');
      expect(s.isStudent, isTrue);
      expect(s.isLecturer, isFalse);
    });

    test('lecturer is lecturer', () {
      expect(u('lecturer').isLecturer, isTrue);
    });

    test('kiu_admin has lecturer attendance access', () {
      // hasLecturerAttendanceAccess = lecturer | kiu_admin
      expect(u('kiu_admin').isLecturer, isTrue);
      expect(u('kiu_admin').isStudent, isFalse);
    });

    test('qa_staff is not routed to lecturer surface', () {
      expect(u('qa_staff').isLecturer, isFalse);
    });
  });

  group('User.fromJson', () {
    test('parses the /me projection', () {
      final user = User.fromJson({
        'id': 'u1',
        'email': 'stu@kiu.ac.ug',
        'fullName': 'Test Student',
        'role': 'student',
        'emailVerified': false,
        'registrationNumber': 'KIU3454S',
      });
      expect(user.id, 'u1');
      expect(user.isStudent, isTrue);
      expect(user.registrationNumber, 'KIU3454S');
    });

    test('tolerates missing optional fields', () {
      final user = User.fromJson({'id': 'u2', 'role': 'lecturer'});
      expect(user.isLecturer, isTrue);
      expect(user.registrationNumber, isNull);
      expect(user.emailVerified, isFalse);
    });
  });
}
