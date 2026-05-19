import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:cryptography_plus/cryptography_plus.dart';

/// AES-256-GCM with PBKDF2-SHA256 password→key derivation.
///
/// On-disk format (text):
///   line 1:  `LIMOUSINE-ENC v1`
///   line 2:  base64( salt(16) || nonce(12) || ciphertext || tag(16) )
///
/// 200k PBKDF2 iterations per derive. Per-file random salt and nonce.
class SecretsCipher {
  static const _header = 'LIMOUSINE-ENC v1';
  static const _saltLen = 16;
  static const _nonceLen = 12;
  static const _pbkdf2Iterations = 200000;
  static const _stampPlaintext = 'limousine-secret-store-v1';

  static final _aes = AesGcm.with256bits();
  static final _kdf = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: _pbkdf2Iterations,
    bits: 256,
  );
  static final _rng = Random.secure();

  static Future<SecretKey> _deriveKey(String password, List<int> salt) {
    return _kdf.deriveKey(
      secretKey: SecretKey(utf8.encode(password)),
      nonce: salt,
    );
  }

  static List<int> _randomBytes(int n) =>
      List<int>.generate(n, (_) => _rng.nextInt(256));

  /// Encrypt [plaintext] with [password]. Returns the text wrapper.
  static Future<String> encrypt(List<int> plaintext, String password) async {
    final salt = _randomBytes(_saltLen);
    final nonce = _randomBytes(_nonceLen);
    final key = await _deriveKey(password, salt);
    final box = await _aes.encrypt(
      plaintext,
      secretKey: key,
      nonce: nonce,
    );
    final blob = Uint8List.fromList(salt + nonce + box.cipherText + box.mac.bytes);
    return '$_header\n${base64.encode(blob)}\n';
  }

  /// Decrypt content produced by [encrypt]. Returns plaintext bytes.
  /// Throws [SecretsCipherException] for any failure (header / base64 / auth tag).
  static Future<Uint8List> decrypt(String content, String password) async {
    final lines = content.split('\n');
    if (lines.length < 2 || lines[0].trim() != _header) {
      throw SecretsCipherException('Not a $_header file');
    }
    final blob = base64.decode(lines[1].trim());
    if (blob.length < _saltLen + _nonceLen + 16) {
      throw SecretsCipherException('Encrypted blob too short');
    }
    final salt = blob.sublist(0, _saltLen);
    final nonce = blob.sublist(_saltLen, _saltLen + _nonceLen);
    final tag = blob.sublist(blob.length - 16);
    final cipherText = blob.sublist(_saltLen + _nonceLen, blob.length - 16);

    final key = await _deriveKey(password, salt);
    try {
      final plain = await _aes.decrypt(
        SecretBox(cipherText, nonce: nonce, mac: Mac(tag)),
        secretKey: key,
      );
      return Uint8List.fromList(plain);
    } on SecretBoxAuthenticationError {
      throw SecretsCipherException('Wrong password or corrupted file');
    } catch (e) {
      throw SecretsCipherException('Decryption failed: $e');
    }
  }

  /// True if [content] begins with the canonical header line.
  static bool looksEncrypted(String content) =>
      content.startsWith(_header);

  // -- Secret-store stamp ---------------------------------------------------

  /// Encrypt the stamp constant with [password] and write to [stampPath].
  /// Used on the *first* server start for a workspace that has no stamp yet.
  static Future<void> createStamp(String stampPath, String password) async {
    final wrapped = await encrypt(utf8.encode(_stampPlaintext), password);
    final f = File(stampPath);
    await f.parent.create(recursive: true);
    await f.writeAsString(wrapped);
  }

  /// True iff decrypting the stamp at [stampPath] with [password] yields the
  /// known plaintext. Wrong password → false (auth-tag fail). Missing /
  /// corrupt file → false.
  static Future<bool> verifyStamp(String stampPath, String password) async {
    final f = File(stampPath);
    if (!await f.exists()) return false;
    try {
      final content = await f.readAsString();
      final plain = await decrypt(content, password);
      return utf8.decode(plain) == _stampPlaintext;
    } catch (_) {
      return false;
    }
  }
}

class SecretsCipherException implements Exception {
  final String message;
  SecretsCipherException(this.message);
  @override
  String toString() => message;
}
