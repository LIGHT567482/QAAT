class QrFields {
  final String studentId;
  final String tenantId;
  final String courseId;
  final String fullName;
  final String academicYear;
  final String serialNumber;
  final String expiryDate;
  final String issuedAt;

  const QrFields({
    required this.studentId,
    required this.tenantId,
    required this.courseId,
    required this.fullName,
    required this.academicYear,
    required this.serialNumber,
    required this.expiryDate,
    required this.issuedAt,
  });
}

class SubmittedQr {
  final QrFields fields;
  final String signatureB64;

  const SubmittedQr({required this.fields, required this.signatureB64});
}

class ActiveSession {
  final String sessionId;
  final String tenantId;
  final String academicYear;
  final String institutionPublicKeyPem;
  final String studentHashKey;
  final Set<String> rosterHashes;
  final Map<String, String> rosterSerials;

  const ActiveSession(
    this.sessionId,
    this.tenantId,
    this.academicYear,
    this.institutionPublicKeyPem,
    this.studentHashKey,
    this.rosterHashes,
    this.rosterSerials,
  );
}

class DeviceContext {
  final String fingerprintHash;

  const DeviceContext(this.fingerprintHash);
}

class DeviceBinding {
  final String studentIdHash;
  final String fingerprintHash;
  final String academicYear;
  final String firstBoundAt;

  const DeviceBinding(
    this.studentIdHash,
    this.fingerprintHash,
    this.academicYear,
    this.firstBoundAt,
  );
}

class AttendanceRecord {
  final String logId;
  final String sessionId;
  final String studentIdHash;
  final String deviceFingerprintHash;
  final int sequenceNumber;
  final String checkinTimestamp;
  final String entryMethod;

  const AttendanceRecord({
    required this.logId,
    required this.sessionId,
    required this.studentIdHash,
    required this.deviceFingerprintHash,
    required this.sequenceNumber,
    required this.checkinTimestamp,
    this.entryMethod = 'QR_SCAN',
  });
}

enum ValidationStatus { present, rejected }

enum RejectionReason {
  invalidSignature,
  qrExpired,
  tenantMismatch,
  notOnRoster,
  serialRevoked,
  deviceMismatch,
  deviceBelongsToAnotherStudent,
  duplicateScan,
  deviceAlreadyUsed,
  sessionNotActive,
  gateNotOpen,
}

class ValidationResult {
  final ValidationStatus status;
  final RejectionReason? reason;
  final String? studentIdHash;
  final String? auditFlag;

  const ValidationResult.present({this.studentIdHash})
      : status = ValidationStatus.present,
        reason = null,
        auditFlag = null;

  const ValidationResult.rejected(
    this.reason, {
    this.studentIdHash,
    this.auditFlag,
  }) : status = ValidationStatus.rejected;
}