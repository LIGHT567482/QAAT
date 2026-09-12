import 'models.dart';

class LecturerScan {
  final String lecturerId;
  final String scannedAt;
  final String fingerprintHash;
  final String endedAt;
  final String endFingerprintHash;

  const LecturerScan(
    this.lecturerId,
    this.scannedAt,
    this.fingerprintHash, {
    this.endedAt = '',
    this.endFingerprintHash = '',
  });
}

class SessionPackage {
  static String build({
    required String sessionId,
    required String coordinatorId,
    required List<AttendanceRecord> records,
    required String sealedAt,
    String unitId = '',
    String sessionDate = '',
    LecturerScan? lecturer,
    String sessionStatus = 'CLOSED',
    String packageVersion = '1.0',
  }) {
    final recsJson = records.map((r) => '{'
        '"log_id":"${_esc(r.logId)}",'
        '"session_id":"${_esc(r.sessionId)}",'
        '"student_id_hash":"${_esc(r.studentIdHash)}",'
        '"device_fingerprint_hash":"${_esc(r.deviceFingerprintHash)}",'
        '"sequence_number":${r.sequenceNumber},'
        '"checkin_timestamp":"${_esc(r.checkinTimestamp)}",'
        '"entry_method":"${_esc(r.entryMethod)}"'
        '}').join(',');
    final l = lecturer;
    final lecturerJson = l != null
        ? ',"lecturer":{'
            '"lecturer_id":"${_esc(l.lecturerId)}",'
            '"scanned_at":"${_esc(l.scannedAt)}",'
            '"fingerprint_hash":"${_esc(l.fingerprintHash)}",'
            '"ended_at":"${_esc(l.endedAt)}",'
            '"end_fingerprint_hash":"${_esc(l.endFingerprintHash)}"'
            '}'
        : '';
    return '{'
        '"session":{"session_id":"${_esc(sessionId)}","unit_id":"${_esc(unitId)}",'
        '"session_date":"${_esc(sessionDate)}","session_status":"${_esc(sessionStatus)}"},'
        '"attendance_records":[$recsJson]'
        '$lecturerJson'
        ',"sealed_at":"${_esc(sealedAt)}",'
        '"coordinator_id":"${_esc(coordinatorId)}",'
        '"package_version":"${_esc(packageVersion)}"'
        '}';
  }

  static String _esc(String s) {
    final sb = StringBuffer();
    for (final code in s.runes) {
      final c = String.fromCharCode(code);
      switch (c) {
        case '\\':
          sb.write(r'\\');
        case '"':
          sb.write(r'\"');
        case '\n':
          sb.write(r'\n');
        case '\r':
          sb.write(r'\r');
        case '\t':
          sb.write(r'\t');
        default:
          if (code < 0x20) {
            sb.write('\\u${code.toRadixString(16).padLeft(4, '0')}');
          } else {
            sb.write(c);
          }
      }
    }
    return sb.toString();
  }
}