import 'dart:async';
import 'dart:io';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'env.dart';
import 'secrets_cipher.dart';

final _log = Logger('SecretStore');

enum SecretStoreStatus {
  /// No `LIMOUSINE_SECRETS_PASSWORD` was provided. Server runs but services
  /// with secrets files cannot start.
  missingPassword,

  /// Password supplied + stamp existed + decrypted successfully.
  verified,

  /// Password supplied + no stamp on disk → just created one with this password.
  newStamp,

  /// Password supplied + stamp existed + decryption failed. `bin/server.dart`
  /// treats this as fatal and exits.
  mismatch,
}

class SecretStoreLockedException implements Exception {
  final String message;
  SecretStoreLockedException(this.message);
  @override
  String toString() => message;
}

/// In-memory secrets-decryption gateway. Holds the master password from
/// `LIMOUSINE_SECRETS_PASSWORD` after a successful stamp verify. All secrets
/// files in a workspace are encrypted with this same password.
///
/// Deliberately not called "vault" — that name is taken by HashiCorp Vault
/// and this is a much simpler local-disk feature. No leases, ACLs, policies,
/// audit log, or tokens. One password, file-based storage.
class SecretStore {
  String? _password;
  SecretStoreStatus _status = SecretStoreStatus.missingPassword;
  String? _workspaceDir;

  final StreamController<SecretStoreStatus> _changes =
      StreamController<SecretStoreStatus>.broadcast();

  Stream<SecretStoreStatus> get changes => _changes.stream;
  SecretStoreStatus get status => _status;
  bool get unlocked => _password != null;

  String? stampPathFor(String workspacePath) {
    final dir = p.dirname(workspacePath);
    return p.join(dir, '.limousine', 'secret-store-stamp');
  }

  void _setStatus(SecretStoreStatus s) {
    _status = s;
    _changes.add(s);
  }

  /// Called once per workspace open. Reads `LIMOUSINE_SECRETS_PASSWORD` from
  /// env and verifies-or-creates the stamp.
  Future<void> initForWorkspace(String workspacePath) async {
    _workspaceDir = p.dirname(workspacePath);
    final password = Platform.environment['LIMOUSINE_SECRETS_PASSWORD'];
    _password = null;
    if (password == null || password.isEmpty) {
      _setStatus(SecretStoreStatus.missingPassword);
      _log.warning(
        'LIMOUSINE_SECRETS_PASSWORD not set — secret store locked. '
        'Services with encrypted secrets will refuse to start.',
      );
      return;
    }

    final stampPath = stampPathFor(workspacePath)!;
    final stamp = File(stampPath);
    if (!await stamp.exists()) {
      _log.info('No secret-store stamp at $stampPath — creating one.');
      await SecretsCipher.createStamp(stampPath, password);
      _password = password;
      _setStatus(SecretStoreStatus.newStamp);
      _log.info(
        'Secret-store stamp created. This password is now bound to '
        '${p.basename(workspacePath)}. Restart with a different password '
        'and the server will refuse to start.',
      );
      return;
    }

    final ok = await SecretsCipher.verifyStamp(stampPath, password);
    if (ok) {
      _password = password;
      _setStatus(SecretStoreStatus.verified);
      _log.info('Secret-store stamp verified.');
    } else {
      _password = null;
      _setStatus(SecretStoreStatus.mismatch);
      _log.severe(
        'SECRET-STORE PASSWORD MISMATCH for ${p.basename(workspacePath)}. '
        'Restart the server with the correct LIMOUSINE_SECRETS_PASSWORD, '
        'or delete $stampPath plus all encrypted .env.secrets.* files to start fresh.',
      );
    }
  }

  /// Constant-time-ish comparison of a candidate password against the stored
  /// password. Used to gate the per-request password header on the
  /// value-bearing API endpoints. Returns false if the store is locked.
  bool verifyHeaderPassword(String candidate) {
    final p = _password;
    if (p == null) return false;
    if (candidate.length != p.length) return false;
    var diff = 0;
    for (var i = 0; i < p.length; i++) {
      diff |= p.codeUnitAt(i) ^ candidate.codeUnitAt(i);
    }
    return diff == 0;
  }

  /// Decrypt the encrypted secrets file at [path] using the stored password.
  /// Returns the parsed key-value map. Empty map if the file doesn't exist.
  /// Throws [SecretStoreLockedException] if the store is locked or the file
  /// is plaintext (no back-compat).
  Future<Map<String, String>> loadSecrets(String path) async {
    final file = File(path);
    if (!await file.exists()) return <String, String>{};
    final password = _password;
    if (password == null) {
      throw SecretStoreLockedException(
        'Secret store is locked. Restart the server with LIMOUSINE_SECRETS_PASSWORD set.',
      );
    }
    final content = await file.readAsString();
    if (!SecretsCipher.looksEncrypted(content)) {
      throw SecretStoreLockedException(
        'Secrets file $path is not encrypted. Remove it (or re-add the keys '
        'via the UI) — limousine no longer reads plaintext secrets.',
      );
    }
    final plain = await SecretsCipher.decrypt(content, password);
    return Env.parseEnvLines(String.fromCharCodes(plain).split('\n'));
  }

  /// Encrypt and write [content] to [path] using the stored password.
  Future<void> saveSecrets(String path, Map<String, String> content) async {
    final password = _password;
    if (password == null) {
      throw SecretStoreLockedException(
        'Secret store is locked. Cannot save encrypted secrets.',
      );
    }
    final plain = Env.serialize(content);
    final wrapped = await SecretsCipher.encrypt(plain.codeUnits, password);
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(wrapped);
  }

  Future<void> dispose() async {
    _password = null;
    await _changes.close();
  }

  String? get workspaceDir => _workspaceDir;
}
