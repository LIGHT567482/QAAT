import 'package:coordinator_flutter/crypto/sealer.dart';
import 'package:coordinator_flutter/crypto/vault_crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('VaultCrypto', () {
    test('sha256 matches the RFC/OpenSSL vector', () {
      expect(
        VaultCrypto.sha256('hello'),
        '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824',
      );
    });

    test('hmacHex matches the RFC 4231 vector', () {
      expect(
        VaultCrypto.hmacHex('key', 'The quick brown fox jumps over the lazy dog'),
        'f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8',
      );
    });

    test('encrypt/decrypt round-trips AES-256-GCM', () {
      final keys = VaultCrypto.deriveKeys('server-issued-binding-secret');
      final ct = VaultCrypto.encrypt(keys.aesKey, '{"session":{}}');
      expect(ct, isNot('{"session":{}}'));
      expect(VaultCrypto.decrypt(keys.aesKey, ct), '{"session":{}}');
    });

    test('encrypt is non-deterministic (fresh IV each time)', () {
      final keys = VaultCrypto.deriveKeys('server-issued-binding-secret');
      final a = VaultCrypto.encrypt(keys.aesKey, 'same plaintext');
      final b = VaultCrypto.encrypt(keys.aesKey, 'same plaintext');
      expect(a, isNot(b));
    });

    test('wrong key fails to decrypt', () {
      final k1 = VaultCrypto.deriveKeys('secret-a');
      final k2 = VaultCrypto.deriveKeys('secret-b');
      final ct = VaultCrypto.encrypt(k1.aesKey, 'payload');
      expect(() => VaultCrypto.decrypt(k2.aesKey, ct), throwsA(anything));
    });

    test('deriveKeys is stable', () {
      final a = VaultCrypto.deriveKeys('x');
      final b = VaultCrypto.deriveKeys('x');
      expect(a.aesKey, b.aesKey);
      expect(a.hmacKey, b.hmacKey);
      expect(a.aesKey.length, 32);
      expect(a.hmacKey.length, 32);
      expect(a.aesKey, isNot(a.hmacKey));
    });
  });

  group('Sealer', () {
    test('seal produces the package the Go receiver expects', () {
      const bindingKey = 'hex-binding-secret';
      final pkg = Sealer.seal(bindingKey, '{"a":1}');

      final keys = VaultCrypto.deriveKeys(bindingKey);
      expect(
        VaultCrypto.hmacSign(keys.hmacKey, pkg.encryptedPayload),
        pkg.hmac,
      );
      expect(
        VaultCrypto.sha256(pkg.encryptedPayload),
        pkg.packageChecksum,
      );
      expect(pkg.totalChunks, (pkg.encryptedPayload.length / Sealer.chunkSize).ceil());
      expect(
        VaultCrypto.decrypt(keys.aesKey, pkg.encryptedPayload),
        '{"a":1}',
      );
    });
  });
}