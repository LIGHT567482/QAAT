import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/asn1.dart';
import 'package:pointycastle/asymmetric/api.dart';
import 'package:pointycastle/api.dart' as pc show PublicKeyParameter, Signer;

class QrPayload {
  final String studentId;
  final String tenantId;
  final String courseId;
  final String fullName;
  final String academicYear;
  final String serialNumber;
  final String expiryDate;
  final String issuedAt;

  const QrPayload(
    this.studentId,
    this.tenantId,
    this.courseId,
    this.fullName,
    this.academicYear,
    this.serialNumber,
    this.expiryDate,
    this.issuedAt,
  );
}

class QrVerify {
  static String canonicalBody(QrPayload p) {
    String esc(String s) => s
        .replaceAll(r'\', r'\\')
        .replaceAll('"', r'\"')
        .replaceAll('\n', r'\n')
        .replaceAll('\r', r'\r')
        .replaceAll('\t', r'\t');
    return '{'
        '"student_id":"${esc(p.studentId)}",'
        '"tenant_id":"${esc(p.tenantId)}",'
        '"course_id":"${esc(p.courseId)}",'
        '"full_name":"${esc(p.fullName)}",'
        '"academic_year":"${esc(p.academicYear)}",'
        '"serial_number":"${esc(p.serialNumber)}",'
        '"expiry_date":"${esc(p.expiryDate)}",'
        '"issued_at":"${esc(p.issuedAt)}"'
        '}';
  }

  static bool verify(String publicKeyPem, String body, String signatureB64) {
    final pub = _parsePublicKey(publicKeyPem);
    final signer = pc.Signer('SHA-256/RSA')
      ..init(false, pc.PublicKeyParameter<RSAPublicKey>(pub));
    final sig = base64Decode(signatureB64);
    return signer.verifySignature(utf8.encode(body), RSASignature(sig));
  }

  static bool verifyPayload(String publicKeyPem, QrPayload p, String signatureB64) =>
      verify(publicKeyPem, canonicalBody(p), signatureB64);

  static RSAPublicKey _parsePublicKey(String pem) {
    final b64 = pem
        .replaceAll('-----BEGIN PUBLIC KEY-----', '')
        .replaceAll('-----END PUBLIC KEY-----', '')
        .replaceAll(RegExp(r'\s'), '');
    final der = base64Decode(b64);
    final parser = ASN1Parser(Uint8List.fromList(der));
    final spki = ASN1SubjectPublicKeyInfo.fromSequence(parser.nextObject() as ASN1Sequence);
    final encoded = spki.subjectPublicKey.stringValues;
    if (encoded == null) {
      throw const FormatException('missing RSA public key bit string');
    }
    final rsa = ASN1Sequence.fromBytes(Uint8List.fromList(encoded));
    final modulus = (rsa.elements![0] as ASN1Integer).integer!;
    final exponent = (rsa.elements![1] as ASN1Integer).integer!;
    return RSAPublicKey(modulus, exponent);
  }
}