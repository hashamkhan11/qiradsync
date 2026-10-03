import 'key_store.dart';

/// Saves the device's bearer token (spec 7.2). It lives in the same secure
/// storage as the private key (CLAUDE.md rule 9), never in the record store.
///
/// The token is not a secret that proves a partner, but it lets anyone who has
/// it download the partnership's records, so it is treated as a secret.
class TokenStore {
  TokenStore(this._secrets);

  /// The `v1` lets a later format change read the old one, as in [KeyStore].
  static const _tokenName = 'qirad.device_token.v1';

  final SecretStore _secrets;

  Future<void> save(String token) => _secrets.write(_tokenName, token);

  /// Returns the saved token, or `null` if this device has not registered yet.
  Future<String?> load() => _secrets.read(_tokenName);
}
