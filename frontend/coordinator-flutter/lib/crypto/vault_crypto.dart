import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/modes/gcm.dart';

class VaultKeys {
  final Uint8List aesKey;
  final Uint8List hmacKey;

  VaultKeys(this.aesKey, this.hmacKey);
}

class VaultCrypto {
  static final Uint8List _salt = Uint8List.fromList(utf8.encode('QAAT-IndexedDB-Salt-v1'));
  static final Uint8List _infoAes = Uint8List.fromList(utf8.encode('coordinator-vault-key'));
  static final Uint8List _infoHmac = Uint8List.fromList(utf8.encode('coordinator-vault-hmac'));
  static const int _ivLen = 12;
  static final Random _rng = Random.secure();

  static VaultKeys deriveKeys(String bindingKey) {
    final secret = Uint8List.fromList(utf8.encode(bindingKey));
    return VaultKeys(
      _hkdfSha256(secret, _salt, _infoAes, 32),
      _hkdfSha256(secret, _salt, _infoHmac, 32),
    );
  }

  static String encrypt(Uint8List aesKey, String plaintext) {
    final iv = Uint8List(_ivLen);
    for (var i = 0; i < _ivLen; i++) {
      iv[i] = _rng.nextInt(256);
    }
    final cipher = GCMBlockCipher(BlockCipher('AES'))
      ..init(true, AEADParameters(KeyParameter(aesKey), 128, iv, Uint8List(0)));
    final ct = cipher.process(Uint8List.fromList(utf8.encode(plaintext)));
    final combined = BytesBuilder()..add(iv)..add(ct);
    return base64Encode(combined.toBytes());
  }

  static String decrypt(Uint8List aesKey, String b64) {
    final combined = base64Decode(b64);
    final iv = Uint8List.sublistView(combined, 0, _ivLen);
    final ctAndTag = Uint8List.sublistView(combined, _ivLen);
    final cipher = GCMBlockCipher(BlockCipher('AES'))
      ..init(false, AEADParameters(KeyParameter(aesKey), 128, iv, Uint8List(0)));
    final pt = cipher.process(ctAndTag);
    return utf8.decode(pt);
  }

  static String hmacSign(Uint8List hmacKey, String data) =>
      _hex(crypto.Hmac(crypto.sha256, hmacKey).convert(utf8.encode(data)).bytes);

  static String sha256(String data) => crypto.sha256.convert(utf8.encode(data)).toString();

  static String hmacHex(String keyStr, String message) =>
      _hex(crypto.Hmac(crypto.sha256, utf8.encode(keyStr)).convert(utf8.encode(message)).bytes);

  static Uint8List _hkdfSha256(Uint8List ikm, Uint8List salt, Uint8List info, int length) {
    final prk = crypto.Hmac(crypto.sha256, salt).convert(ikm).bytes;
    final out = BytesBuilder();
    var t = <int>[];
    var counter = 1;
    while (out.length < length) {
      t = crypto.Hmac(crypto.sha256, prk)
          .convert([...t, ...info, counter])
          .bytes;
      out.add(t);
      counter++;
    }
    return Uint8List.sublistView(out.toBytes(), 0, length);
  }

  static String _hex(List<int> b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
}