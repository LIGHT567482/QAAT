import '../crypto/vault_crypto.dart' show VaultCrypto, VaultKeys;

class SealedPackage {
  final String encryptedPayload;
  final String hmac;
  final String packageChecksum;
  final int totalChunks;

  const SealedPackage(
    this.encryptedPayload,
    this.hmac,
    this.packageChecksum,
    this.totalChunks,
  );
}

class Sealer {
  static const int chunkSize = 65536;

  static SealedPackage seal(String bindingKey, String plaintextJson) {
    final VaultKeys keys = VaultCrypto.deriveKeys(bindingKey);
    final encPayload = VaultCrypto.encrypt(keys.aesKey, plaintextJson);
    final hmac = VaultCrypto.hmacSign(keys.hmacKey, encPayload);
    final checksum = VaultCrypto.sha256(encPayload);
    final totalChunks = (encPayload.length / chunkSize).ceil();
    return SealedPackage(encPayload, hmac, checksum, totalChunks);
  }
}