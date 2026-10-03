import 'package:qirad_core/qirad_core.dart';

import '../storage/token_store.dart';
import 'relay_client.dart';

/// Gives the sync runner a bearer token, and registers the device when it has
/// none (spec 7.2). Registration needs proof that the phone holds the key:
/// the relay sends a nonce, and the phone signs it.
class DeviceSession {
  DeviceSession({
    required this.keys,
    required this.relay,
    required this.tokens,
  });

  final Ed25519KeyPair keys;
  final RelayClient relay;
  final TokenStore tokens;

  /// The saved token. If none is saved yet, registers first.
  Future<String> token() async {
    final saved = await tokens.load();
    if (saved != null) return saved;
    return register();
  }

  /// Always asks the relay for a new token: challenge, signed proof, then
  /// save. The sync runner calls this after a 401, when the relay no longer
  /// accepts the saved token.
  Future<String> register() async {
    final publicKey = keys.publicKeyBase64Url;
    final nonce = await relay.requestChallenge(publicKey: publicKey);
    final signature = await signRegistrationChallenge(keys, nonce);
    final token = await relay.register(
      publicKey: publicKey,
      nonce: nonce,
      signature: signature,
    );
    await tokens.save(token);
    return token;
  }
}
