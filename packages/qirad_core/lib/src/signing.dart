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

Map<String, dynamic> _withoutSig(Map<String, dynamic> json) {
  return Map<String, dynamic>.from(json)..remove('sig');
}
