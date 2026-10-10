import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:qirad_core/qirad_core.dart';

/// A small key-value store for secrets. The app uses the platform's secure
/// storage; tests use an in-memory fake.
abstract interface class SecretStore {
  Future<String?> read(String name);
  Future<void> write(String name, String value);
}

/// The real store: Android Keystore on phones (docs/spec.md, section 2).
class PlatformSecretStore implements SecretStore {
  PlatformSecretStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String name) => _storage.read(key: name);

  @override
  Future<void> write(String name, String value) =>
      _storage.write(key: name, value: value);
}

/// Saves and loads the phone's private key.
///
/// Only the 32-byte seed is saved. The public key is calculated from it when
/// the key is loaded, so the two can never disagree. The seed is never written
/// to the record store, to logs, or into any record.
class KeyStore {
  KeyStore(this._secrets);

  /// The name of the saved seed. The `v1` lets a later format change read the old one.
  static const _seedName = 'qirad.private_key.v1';

  final SecretStore _secrets;

  Future<void> save(Ed25519KeyPair pair) =>
      _secrets.write(_seedName, encodeBase64UrlNoPadding(pair.privateKeyBytes));

  /// Returns the saved key pair, or `null` if none has been saved yet.
  Future<Ed25519KeyPair?> load() async {
    final text = await _secrets.read(_seedName);
    if (text == null) return null;
    return ed25519KeyPairFromSeed(decodeBase64UrlNoPadding(text));
  }

  /// Returns the phone's key pair, making and saving one on the first run.
  ///
  /// Each phone has one key for its life. Making a second key here would
  /// give the partner a new identity that no pinned partnership knows.
  Future<Ed25519KeyPair> loadOrCreate() async {
    final existing = await load();
    if (existing != null) return existing;
    final pair = await generateEd25519KeyPair();
    await save(pair);
    return pair;
  }
}
