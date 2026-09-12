import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:coordinator_flutter/crypto/qr_verify.dart';
import 'package:coordinator_flutter/crypto/vault_crypto.dart';
import 'package:coordinator_flutter/engine/checkin_validator.dart';
import 'package:coordinator_flutter/engine/models.dart';
import 'package:coordinator_flutter/engine/store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/api.dart' as pc;
import 'package:pointycastle/asn1.dart';
import 'package:pointycastle/asymmetric/api.dart';
import 'package:pointycastle/key_generators/api.dart';

class RecordedKey {
  final String pem;
  final pc.Signer signer;

  RecordedKey(this.pem, this.signer);
}

RecordedKey _makeKey() {
  final rng = Random.secure();
  final entropy = Uint8List.fromList(List<int>.generate(32, (_) => rng.nextInt(256)));
  final random = pc.SecureRandom('Fortuna')..seed(pc.KeyParameter(entropy));
  final gen = pc.KeyGenerator('RSA')
    ..init(pc.ParametersWithRandom(
      RSAKeyGeneratorParameters(BigInt.from(65537), 1024, 80),
      random,
    ));
  final pair = gen.generateKeyPair() as pc.AsymmetricKeyPair<RSAPublicKey, RSAPrivateKey>;
  final rsaSeq = ASN1Sequence(elements: [
    ASN1Integer(pair.publicKey.modulus!),
    ASN1Integer(pair.publicKey.exponent!),
  ]);
  final spki = ASN1SubjectPublicKeyInfo(
    ASN1AlgorithmIdentifier.fromIdentifier('1.2.840.113549.1.1.1'),
    ASN1BitString(stringValues: rsaSeq.encode()),
  );
  final der = spki.encode();
  final pem = '-----BEGIN PUBLIC KEY-----\n${base64Encode(der)}\n-----END PUBLIC KEY-----\n';
  final signer = pc.Signer('SHA-256/RSA')
    ..init(true, pc.PrivateKeyParameter<RSAPrivateKey>(pair.privateKey));
  return RecordedKey(pem, signer);
}

class RSession {
  final String tenantId;
  final String academicYear;
  final Set<String> roster;
  final Map<String, String> serials;

  RSession({
    this.tenantId = 'tenant-abc',
    this.academicYear = '2026/2027',
    required this.roster,
    required this.serials,
  });
}

void main() {
  const hashKey = 'per-tenant-hmac-key';
  late RecordedKey key;

  setUpAll(() {
    key = _makeKey();
  });

  const payload = QrPayload(
    '2026/BSCS/001',
    'tenant-abc',
    'course-1',
    'Anne Student',
    '2026/2027',
    'SER-100',
    '2027-12-31',
    '2026-06-01T00:00:00Z',
  );

  String signedRawQr({QrPayload p = payload, String? forceSerial}) {
    final body = QrVerify.canonicalBody(p);
    final sig = key.signer.generateSignature(utf8.encode(body)) as RSASignature;
    return jsonEncode({
      'student_id': p.studentId,
      'tenant_id': p.tenantId,
      'course_id': p.courseId,
      'full_name': p.fullName,
      'academic_year': p.academicYear,
      'serial_number': forceSerial ?? p.serialNumber,
      'expiry_date': p.expiryDate,
      'issued_at': p.issuedAt,
      'signature': base64Encode(sig.bytes),
    });
  }

  ActiveSession session(RSession r) => ActiveSession(
        'sess1',
        r.tenantId,
        r.academicYear,
        key.pem,
        hashKey,
        r.roster,
        r.serials,
      );

  CheckinValidator validator(InMemoryStore store, {int? clock}) {
    final now = clock ?? DateTime.utc(2026, 6, 29).millisecondsSinceEpoch;
    return CheckinValidator(
      store,
      nowMillis: () => now,
      nowIso: () => '2026-06-29T00:00:00Z',
      newUuid: () => 'uuid-fixed',
    );
  }

  RSession happySession() {
    final h = VaultCrypto.hmacHex(hashKey, payload.studentId);
    return RSession(roster: {h}, serials: {h: payload.serialNumber});
  }

  test('present path writes one record with increasing sequence', () {
    final h = VaultCrypto.hmacHex(hashKey, payload.studentId);
    final store = InMemoryStore();
    final r = validator(store)
        .validate(signedRawQr(), session(happySession()), const DeviceContext('fpA'));
    expect(r.status, ValidationStatus.present);
    final rows = store.all();
    expect(rows.length, 1);
    expect(rows[0].sequenceNumber, 1);
    expect(rows[0].studentIdHash, h);
    expect(rows[0].entryMethod, 'QR_SCAN');
  });

  test('duplicate scan rejected', () {
    final store = InMemoryStore();
    final v = validator(store);
    final s = session(happySession());
    expect(v.validate(signedRawQr(), s, const DeviceContext('fpA')).status,
        ValidationStatus.present);
    final r = v.validate(signedRawQr(), s, const DeviceContext('fpA'));
    expect(r.status, ValidationStatus.rejected);
    expect(r.reason, RejectionReason.duplicateScan);
  });

  test('tampered signature rejected', () {
    final raw = signedRawQr();
    final sigStart = raw.indexOf('"signature":"') + 13;
    final sigEnd = raw.indexOf('"}', sigStart);
    final tampered = raw.substring(0, sigStart) +
        (raw[sigStart] == 'A' ? 'B' : 'A') +
        raw.substring(sigStart + 1, sigEnd) +
        raw.substring(sigEnd);
    final r = validator(InMemoryStore())
        .validate(tampered, session(happySession()), const DeviceContext('fpA'));
    expect(r.status, ValidationStatus.rejected);
    expect(r.reason, RejectionReason.invalidSignature);
  });

  test('tenant mismatch rejected', () {
    final f = payload;
    final h = VaultCrypto.hmacHex(hashKey, f.studentId);
    final r = validator(InMemoryStore()).validate(
        signedRawQr(),
        session(RSession(
          tenantId: 'someone-else',
          roster: {h},
          serials: {h: f.serialNumber},
        )),
        const DeviceContext('fpA'));
    expect(r.reason, RejectionReason.tenantMismatch);
  });

  test('not on roster rejected', () {
    final r = validator(InMemoryStore()).validate(
        signedRawQr(),
        session(RSession(roster: {}, serials: {})),
        const DeviceContext('fpA'));
    expect(r.reason, RejectionReason.notOnRoster);
  });

  test('superseded serial rejected', () {
    final f = payload;
    final h = VaultCrypto.hmacHex(hashKey, f.studentId);
    final r = validator(InMemoryStore()).validate(
        signedRawQr(),
        session(RSession(roster: {h}, serials: {h: 'OLD-SERIAL'})),
        const DeviceContext('fpA'));
    expect(r.reason, RejectionReason.serialRevoked);
  });

  test('device bound to another fingerprint → device mismatch', () {
    final f = payload;
    final h = VaultCrypto.hmacHex(hashKey, f.studentId);
    final store = InMemoryStore()
      ..putBinding(DeviceBinding(h, 'fpOriginal', f.academicYear, 't'));
    final r = validator(store)
        .validate(signedRawQr(), session(happySession()), const DeviceContext('fpA'));
    expect(r.reason, RejectionReason.deviceMismatch);
  });

  test('fingerprint bound to another student rejected', () {
    final store = InMemoryStore()
      ..putBinding(DeviceBinding('other-student-hash', 'fpA', '2026/2027', 't'));
    final r = validator(store)
        .validate(signedRawQr(), session(happySession()), const DeviceContext('fpA'));
    expect(r.reason, RejectionReason.deviceBelongsToAnotherStudent);
  });

  test('device already used by another student this session rejected', () {
    final store = InMemoryStore()
      ..addAttendance(const AttendanceRecord(
        logId: 'l',
        sessionId: 'sess1',
        studentIdHash: 'another-hash',
        deviceFingerprintHash: 'fpA',
        sequenceNumber: 1,
        checkinTimestamp: 't',
      ));
    final r = validator(store)
        .validate(signedRawQr(), session(happySession()), const DeviceContext('fpA'));
    expect(r.reason, RejectionReason.deviceAlreadyUsed);
  });

  test('expired QR rejected', () {
    final r = validator(
      InMemoryStore(),
      clock: DateTime.utc(2030, 1, 1).millisecondsSinceEpoch,
    ).validate(signedRawQr(), session(happySession()), const DeviceContext('fpA'));
    expect(r.reason, RejectionReason.qrExpired);
  });

  test('reg-number check-in uses the same anti-cheat', () {
    final h = VaultCrypto.hmacHex(hashKey, '2026/BSCS/001');
    final store = InMemoryStore();
    final v = validator(store);
    final s = session(RSession(roster: {h}, serials: {}));
    final r = v.validateReg('2026/BSCS/001', s, const DeviceContext('fpA'));
    expect(r.status, ValidationStatus.present);
    expect(r.studentIdHash, h);
    expect(v.validateReg('2026/BSCS/001', s, const DeviceContext('fpA')).reason,
        RejectionReason.duplicateScan);
  });

  test('empty reg number → not on roster', () {
    final r = validator(InMemoryStore())
        .validateReg('   ', session(RSession(roster: {}, serials: {})), const DeviceContext('fpA'));
    expect(r.reason, RejectionReason.notOnRoster);
  });
}