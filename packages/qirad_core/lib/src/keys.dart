import 'dart:convert';

import 'package:cryptography/cryptography.dart';

/// An Ed25519 key pair, per spec section 2.
///
/// [privateKeyBytes] is the 32-byte seed. It never leaves the device
/// (hard rule) — callers are responsible for secure storage; this class
/// just carries the bytes in memory.
class Ed25519KeyPair {
  final List<int> privateKeyBytes;
  final List<int> publicKeyBytes;

  const Ed25519KeyPair({
    required this.privateKeyBytes,
    required this.publicKeyBytes,
  });

  /// The `author` field value for records signed by this key pair.
  String get publicKeyBase64Url => encodeBase64UrlNoPadding(publicKeyBytes);
}

Future<Ed25519KeyPair> generateEd25519KeyPair() async {
  final keyPair = await Ed25519().newKeyPair();
  final privateKeyBytes = await keyPair.extractPrivateKeyBytes();
  final publicKey = await keyPair.extractPublicKey();
  return Ed25519KeyPair(
    privateKeyBytes: privateKeyBytes,
    publicKeyBytes: publicKey.bytes,
  );
}

/// Rebuilds a key pair from its 32-byte seed (the private key), for example
/// after the seed was read back from secure storage. The public key is
/// calculated from the seed, so it can never disagree with it.
Future<Ed25519KeyPair> ed25519KeyPairFromSeed(List<int> seed) async {
  if (seed.length != 32) {
    throw ArgumentError.value(seed.length, 'seed.length', 'must be 32 bytes');
  }
  final keyPair = await Ed25519().newKeyPairFromSeed(seed);
  final publicKey = await keyPair.extractPublicKey();
  return Ed25519KeyPair(
    privateKeyBytes: List<int>.of(seed),
    publicKeyBytes: publicKey.bytes,
  );
}

/// Base64url without padding (spec sections 2 and 4.2) — `dart:convert`'s
/// `base64Url` pads with `=`, so that padding is stripped here.
String encodeBase64UrlNoPadding(List<int> bytes) {
  return base64Url.encode(bytes).replaceAll('=', '');
}

/// True only for the canonical spelling of a 32-byte public key (spec 2).
///
/// Re-encoding must give back the same text. Two spellings of one key would
/// make a pin refuse every real record, because records always use the
/// canonical spelling.
bool isCanonicalPublicKey(String text) {
  if (text.length != 43) return false;
  try {
    final bytes = decodeBase64UrlNoPadding(text);
    return bytes.length == 32 && encodeBase64UrlNoPadding(bytes) == text;
  } on FormatException {
    return false;
  }
}

/// Reverses [encodeBase64UrlNoPadding] by restoring the padding
/// `base64Url.decode` requires (a length that's a multiple of 4).
List<int> decodeBase64UrlNoPadding(String value) {
  final remainder = value.length % 4;
  final padded = remainder == 0 ? value : value + '=' * (4 - remainder);
  return base64Url.decode(padded);
}
