import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import 'canonical_json.dart';
import 'keys.dart';
import 'record.dart';

/// Signs [unsigned] per spec section 4.2: `sig` is computed over the
/// record's canonical bytes with the `sig` field itself removed first.
/// Whatever placeholder is in [unsigned.sig] is ignored and replaced.
Future<Record> signRecord(Record unsigned, Ed25519KeyPair keyPair) async {
  final bytesToSign = utf8.encode(canonicalJson(_withoutSig(unsigned.toJson())));
  final cryptoKeyPair = await Ed25519().newKeyPairFromSeed(keyPair.privateKeyBytes);
  final signature = await Ed25519().sign(bytesToSign, keyPair: cryptoKeyPair);
  return unsigned.copyWith(sig: encodeBase64UrlNoPadding(signature.bytes));
}

/// Verifies [record].`sig` against [record].`author`, per spec section 4.2.
///
/// This sits at a trust boundary — it decides whether to believe data that
/// may have come from the network — so malformed input (bad base64, wrong
/// key length, etc.) returns `false` rather than throwing.
Future<bool> verifyRecord(Record record) async {
  try {
    final bytesToVerify = utf8.encode(canonicalJson(_withoutSig(record.toJson())));
    final publicKey = SimplePublicKey(
      decodeBase64UrlNoPadding(record.author),
      type: KeyPairType.ed25519,
    );
    final signature = Signature(
      decodeBase64UrlNoPadding(record.sig),
      publicKey: publicKey,
    );
    return await Ed25519().verify(bytesToVerify, signature: signature);
  } catch (_) {
    return false;
  }
}

/// The domain separator for device registration (spec 7.2). It starts every
/// registration message, so a registration signature is never a valid
/// signature over anything a record could contain.
const _registrationPrefix = 'qiradsync-register-v1:';

/// Signs the registration challenge for [nonce] with [keyPair] (spec 7.2,
/// step 2). The prefix is added here, not by the caller, so no caller can
/// sign the bare nonce or any other bytes through this function.
Future<String> signRegistrationChallenge(
  Ed25519KeyPair keyPair,
  String nonce,
) async {
  final bytesToSign = utf8.encode('$_registrationPrefix$nonce');
  final cryptoKeyPair = await Ed25519().newKeyPairFromSeed(
    keyPair.privateKeyBytes,
  );
  final signature = await Ed25519().sign(bytesToSign, keyPair: cryptoKeyPair);
  return encodeBase64UrlNoPadding(signature.bytes);
}

/// True when [signature] is a valid registration signature for [publicKey]
/// and [nonce]. Malformed input returns `false`, as in [verifyRecord]: this
/// also sits at a trust boundary.
Future<bool> verifyRegistrationChallenge({
  required String publicKey,
  required String nonce,
  required String signature,
}) async {
  try {
    final bytesToVerify = utf8.encode('$_registrationPrefix$nonce');
    final key = SimplePublicKey(
      decodeBase64UrlNoPadding(publicKey),
      type: KeyPairType.ed25519,
    );
    final sig = Signature(decodeBase64UrlNoPadding(signature), publicKey: key);
    return await Ed25519().verify(bytesToVerify, signature: sig);
  } catch (_) {
    return false;
  }
}

Map<String, dynamic> _withoutSig(Map<String, dynamic> json) {
  return Map<String, dynamic>.from(json)..remove('sig');
}
