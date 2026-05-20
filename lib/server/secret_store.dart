import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'env.dart';

final _log = Logger('SecretStore');

enum SecretStoreStatus {
  /// No age private key was supplied at startup. Server runs but services
  /// that need encrypted secrets cannot start (their commands will sops-fail).
  missingKey,

  /// Key supplied + stamp existed + decrypted successfully.
  verified,

  /// Key supplied + no stamp on disk → just created one with this key.
  newStamp,

  /// Key supplied + stamp existed + sops decryption failed. `bin/server.dart`
  /// treats this as fatal and exits.
  mismatch,
}

class SecretStoreLockedException implements Exception {
  final String message;
  SecretStoreLockedException(this.message);
  @override
  String toString() => message;
}

/// In-memory secrets gateway, backed by `sops` + `age`. Holds the dev's age
/// private key (pasted at startup via the wrapper) in memory; never touches
/// disk with it. Public key is derived once and cached.
///
/// All encryption / decryption is delegated to the `sops` CLI — see
/// docker/Dockerfile for the pinned versions. Limousine does NOT inject
/// secrets into spawned services anymore; instead the start command in each
/// project's limousine.proj does `sops exec-env .env.secrets -- …` itself.
/// This module's runtime responsibilities are:
///   - validate the key on startup against a `secret-store-stamp` (sops-encrypted)
///   - serve the secrets editor UI (decrypt for view, encrypt on save)
///   - expose the private key so service_manager can forward SOPS_AGE_KEY
///     into spawned child processes
///
/// Deliberately not called "vault" — that name belongs to HashiCorp Vault,
/// and this is a much smaller, single-key local-disk feature.
class SecretStore {
  String? _privateKey; // AGE-SECRET-KEY-…
  String? _publicKey;  // age1…
  SecretStoreStatus _status = SecretStoreStatus.missingKey;
  String? _workspaceDir;

  static const _stampPlaintext = 'limousine-secret-store-v2';

  final StreamController<SecretStoreStatus> _changes =
      StreamController<SecretStoreStatus>.broadcast();

  Stream<SecretStoreStatus> get changes => _changes.stream;
  SecretStoreStatus get status => _status;
  bool get unlocked => _privateKey != null;

  /// The age private key, exposed so service_manager can forward it into
  /// child processes as SOPS_AGE_KEY. Null if the store is locked.
  String? get privateKey => _privateKey;

  String? stampPathFor(String workspacePath) =>
      p.join(p.dirname(workspacePath), '.limousine', 'secret-store-stamp');

  void _setStatus(SecretStoreStatus s) {
    _status = s;
    _changes.add(s);
  }

  /// Read `LIMOUSINE_AGE_KEY` from the environment, validate it by deriving
  /// the public key, then verify or create the workspace stamp file.
  Future<void> initForWorkspace(String workspacePath) async {
    _workspaceDir = p.dirname(workspacePath);
    final keyEnv = Platform.environment['LIMOUSINE_AGE_KEY'];
    _privateKey = null;
    _publicKey = null;

    if (keyEnv == null || keyEnv.isEmpty) {
      _setStatus(SecretStoreStatus.missingKey);
      _log.warning(
        'LIMOUSINE_AGE_KEY not set — secret store locked. '
        'Services with encrypted secrets will fail to decrypt.',
      );
      return;
    }

    final pub = await _derivePublicKey(keyEnv.trim());
    if (pub == null) {
      _setStatus(SecretStoreStatus.mismatch);
      _log.severe(
        'LIMOUSINE_AGE_KEY does not parse as a valid age private key. '
        'Restart with a key produced by `age-keygen`.',
      );
      return;
    }
    _privateKey = keyEnv.trim();
    _publicKey = pub;

    final stampPath = stampPathFor(workspacePath)!;
    if (!await File(stampPath).exists()) {
      _log.info('No secret-store stamp at $stampPath — creating one.');
      try {
        await _createStamp(stampPath);
      } catch (e) {
        _privateKey = null;
        _publicKey = null;
        _setStatus(SecretStoreStatus.mismatch);
        _log.severe('Failed to create stamp: $e');
        return;
      }
      _setStatus(SecretStoreStatus.newStamp);
      _log.info(
        'Secret-store stamp created. This age key is now bound to '
        '${p.basename(workspacePath)}. Restart with a different key and the '
        'server will refuse to start.',
      );
      return;
    }

    final ok = await _verifyStamp(stampPath);
    if (ok) {
      _setStatus(SecretStoreStatus.verified);
      _log.info('Secret-store stamp verified.');
    } else {
      _privateKey = null;
      _publicKey = null;
      _setStatus(SecretStoreStatus.mismatch);
      _log.severe(
        'SECRET-STORE STAMP MISMATCH for ${p.basename(workspacePath)}. '
        'The supplied age key does not decrypt the existing stamp. Restart '
        'with the correct key, or delete $stampPath plus any encrypted '
        '.env.secrets files to start fresh.',
      );
    }
  }

  /// Caller still validates the supplied key against the stored one before
  /// returning secret values over the wire. With sops-on-the-side, this is
  /// just a constant-time-ish equality check against the in-memory key.
  bool verifyHeaderKey(String candidate) {
    final stored = _privateKey;
    if (stored == null) return false;
    final c = candidate.trim();
    if (c.length != stored.length) return false;
    var diff = 0;
    for (var i = 0; i < stored.length; i++) {
      diff |= c.codeUnitAt(i) ^ stored.codeUnitAt(i);
    }
    return diff == 0;
  }

  /// Decrypt the dotenv-formatted, sops-encrypted secrets file at [path].
  Future<Map<String, String>> loadSecrets(String path) async {
    final file = File(path);
    if (!await file.exists()) return <String, String>{};
    final key = _privateKey;
    if (key == null) {
      throw SecretStoreLockedException(
        'Secret store is locked. Restart the server with LIMOUSINE_AGE_KEY set.',
      );
    }
    final result = await _sopsDecrypt(path, key);
    if (result == null) {
      throw SecretStoreLockedException(
        'Failed to decrypt $path. The file may not be sops-encrypted, or it '
        'was encrypted to a different age recipient than the current key.',
      );
    }
    return Env.parseEnvLines(result.split('\n'));
  }

  /// Encrypt [content] (dotenv KV map) and write the sops-armored result to
  /// [path]. Overwrites in place.
  Future<void> saveSecrets(String path, Map<String, String> content) async {
    final pub = _publicKey;
    if (pub == null) {
      throw SecretStoreLockedException(
        'Secret store is locked. Cannot save encrypted secrets.',
      );
    }
    final plain = Env.serialize(content);
    final encrypted = await _sopsEncrypt(plain, pub);
    if (encrypted == null) {
      throw SecretStoreLockedException('sops encrypt failed for $path');
    }
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(encrypted);
  }

  Future<void> dispose() async {
    _privateKey = null;
    _publicKey = null;
    await _changes.close();
  }

  String? get workspaceDir => _workspaceDir;

  // ---------------------------------------------------------------------------
  // sops/age shell-out helpers
  // ---------------------------------------------------------------------------

  Future<String?> _derivePublicKey(String privateKey) async {
    final proc = await Process.start('age-keygen', ['-y']);
    proc.stdin.add(utf8.encode('$privateKey\n'));
    await proc.stdin.close();
    final out = await proc.stdout.transform(utf8.decoder).join();
    final err = await proc.stderr.transform(utf8.decoder).join();
    final code = await proc.exitCode;
    if (code != 0) {
      _log.warning('age-keygen -y failed: $err');
      return null;
    }
    final pub = out.trim();
    if (!pub.startsWith('age1')) {
      _log.warning('age-keygen -y produced unexpected output: $pub');
      return null;
    }
    return pub;
  }

  /// `sops -d --input-type dotenv --output-type dotenv <path>`. Returns
  /// decrypted dotenv text, or null on any failure.
  Future<String?> _sopsDecrypt(String path, String privateKey) async {
    final env = {
      ...Platform.environment,
      'SOPS_AGE_KEY': privateKey,
    };
    final proc = await Process.start(
      'sops',
      [
        '-d',
        '--input-type', 'dotenv',
        '--output-type', 'dotenv',
        path,
      ],
      environment: env,
      includeParentEnvironment: false,
    );
    final out = await proc.stdout.transform(utf8.decoder).join();
    final err = await proc.stderr.transform(utf8.decoder).join();
    final code = await proc.exitCode;
    if (code != 0) {
      _log.warning('sops -d $path failed (exit $code): $err');
      return null;
    }
    return out;
  }

  /// `sops -e --age <pub> --input-type dotenv --output-type dotenv /dev/stdin`.
  /// Returns encrypted text, or null on failure.
  Future<String?> _sopsEncrypt(String plaintext, String publicKey) async {
    // sops doesn't read /dev/stdin reliably for typed inputs; round-trip via a
    // tempfile to make the input-type detection deterministic.
    final tmp = await Directory.systemTemp.createTemp('limousine-sops-');
    final inputPath = p.join(tmp.path, 'in.env');
    try {
      await File(inputPath).writeAsString(plaintext);
      final proc = await Process.start(
        'sops',
        [
          '-e',
          '--age', publicKey,
          '--input-type', 'dotenv',
          '--output-type', 'dotenv',
          inputPath,
        ],
        includeParentEnvironment: true,
      );
      final out = await proc.stdout.transform(utf8.decoder).join();
      final err = await proc.stderr.transform(utf8.decoder).join();
      final code = await proc.exitCode;
      if (code != 0) {
        _log.warning('sops -e failed (exit $code): $err');
        return null;
      }
      return out;
    } finally {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    }
  }

  Future<void> _createStamp(String stampPath) async {
    final pub = _publicKey!;
    final encrypted = await _sopsEncrypt(
      'LIMOUSINE_STAMP=$_stampPlaintext\n',
      pub,
    );
    if (encrypted == null) {
      throw StateError('sops encrypt failed creating stamp');
    }
    final file = File(stampPath);
    await file.parent.create(recursive: true);
    await file.writeAsString(encrypted);
  }

  Future<bool> _verifyStamp(String stampPath) async {
    final key = _privateKey!;
    final decrypted = await _sopsDecrypt(stampPath, key);
    if (decrypted == null) return false;
    return decrypted.contains('LIMOUSINE_STAMP=$_stampPlaintext');
  }
}
