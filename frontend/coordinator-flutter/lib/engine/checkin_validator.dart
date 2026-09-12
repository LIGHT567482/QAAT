import 'dart:math';

import '../crypto/qr_verify.dart' show QrVerify, QrPayload;
import '../crypto/vault_crypto.dart' show VaultCrypto;
import 'flat_json.dart' show FlatJson;
import 'models.dart';
import 'store.dart' show Store;

class CheckinValidator {
  final Store store;
  final bool enforceDeviceLock;
  final int Function() nowMillis;
  final String Function() nowIso;
  final String Function() newUuid;

  CheckinValidator(
    this.store, {
    this.enforceDeviceLock = true,
    int Function()? nowMillis,
    String Function()? nowIso,
    String Function()? newUuid,
  })  : nowMillis = nowMillis ?? _defaultNowMillis,
        nowIso = nowIso ?? _defaultNowIso,
        newUuid = newUuid ?? _defaultNewUuid;

  static int _defaultNowMillis() => DateTime.now().millisecondsSinceEpoch;

  static String _defaultNowIso() => DateTime.now().toUtc().toIso8601String();

  static String _defaultNewUuid() {
    final rng = Random.secure();
    final b = List<int>.generate(16, (_) => rng.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
        '${h.substring(16, 20)}-${h.substring(20)}';
  }

  ValidationResult validate(String rawQr, ActiveSession session, DeviceContext device) {
    final qr = FlatJson.parseQr(rawQr);
    if (qr == null) {
      return const ValidationResult.rejected(RejectionReason.invalidSignature);
    }
    final f = qr.fields;
    final body = QrVerify.canonicalBody(QrPayload(
      f.studentId,
      f.tenantId,
      f.courseId,
      f.fullName,
      f.academicYear,
      f.serialNumber,
      f.expiryDate,
      f.issuedAt,
    ));
    final sigOk = _try(() => QrVerify.verify(session.institutionPublicKeyPem, body, qr.signatureB64));
    if (!sigOk) {
      return const ValidationResult.rejected(RejectionReason.invalidSignature);
    }

    final expiryMs = _parseExpiry(f.expiryDate);
    if (expiryMs == null || expiryMs < nowMillis()) {
      return const ValidationResult.rejected(RejectionReason.qrExpired);
    }

    if (f.tenantId != session.tenantId) {
      return const ValidationResult.rejected(RejectionReason.tenantMismatch);
    }

    final studentIdHash = VaultCrypto.hmacHex(session.studentHashKey, f.studentId);

    final lock = _rosterAndDeviceLock(studentIdHash, session, device);
    if (lock != null) {
      return ValidationResult.rejected(lock);
    }

    final currentSerial = session.rosterSerials[studentIdHash];
    if (currentSerial == null || f.serialNumber != currentSerial) {
      return const ValidationResult.rejected(RejectionReason.serialRevoked);
    }

    return _bindAndRecord(studentIdHash, session, device);
  }

  ValidationResult validateReg(String regNumber, ActiveSession session, DeviceContext device) {
    final reg = regNumber.trim();
    if (reg.isEmpty) {
      return const ValidationResult.rejected(RejectionReason.notOnRoster);
    }
    final studentIdHash = VaultCrypto.hmacHex(session.studentHashKey, reg);
    final lock = _rosterAndDeviceLock(studentIdHash, session, device);
    if (lock != null) {
      return ValidationResult.rejected(lock);
    }
    return _bindAndRecord(studentIdHash, session, device);
  }

  RejectionReason? _rosterAndDeviceLock(String studentIdHash, ActiveSession session, DeviceContext device) {
    if (enforceDeviceLock) {
      final binding = store.bindingByFingerprint(device.fingerprintHash);
      if (binding != null && binding.studentIdHash != studentIdHash) {
        return RejectionReason.deviceBelongsToAnotherStudent;
      }
    }
    if (!session.rosterHashes.contains(studentIdHash)) {
      return RejectionReason.notOnRoster;
    }
    return null;
  }

  ValidationResult _bindAndRecord(String studentIdHash, ActiveSession session, DeviceContext device) {
    final stored = store.bindingByStudent(studentIdHash);
    if (stored != null) {
      if (enforceDeviceLock && stored.fingerprintHash != device.fingerprintHash) {
        return const ValidationResult.rejected(
          RejectionReason.deviceMismatch,
          auditFlag: 'DEVICE_MISMATCH',
        );
      }
    } else {
      store.putBinding(DeviceBinding(
        studentIdHash,
        device.fingerprintHash,
        session.academicYear,
        nowIso(),
      ));
    }
    if (store.hasAttendance(session.sessionId, studentIdHash)) {
      return const ValidationResult.rejected(RejectionReason.duplicateScan);
    }
    if (enforceDeviceLock &&
        store.deviceUsedByOther(session.sessionId, device.fingerprintHash, studentIdHash)) {
      return const ValidationResult.rejected(RejectionReason.deviceAlreadyUsed);
    }
    store.addAttendance(AttendanceRecord(
      logId: newUuid(),
      sessionId: session.sessionId,
      studentIdHash: studentIdHash,
      deviceFingerprintHash: device.fingerprintHash,
      sequenceNumber: store.attendanceCount(session.sessionId) + 1,
      checkinTimestamp: nowIso(),
    ));
    return ValidationResult.present(studentIdHash: studentIdHash);
  }

  static int? _parseExpiry(String date) {
    final dt = DateTime.tryParse(date);
    if (dt == null) return null;
    return DateTime.utc(dt.year, dt.month, dt.day).millisecondsSinceEpoch;
  }

  static bool _try(bool Function() f) {
    try {
      return f();
    } catch (_) {
      return false;
    }
  }
}