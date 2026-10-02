/// Record hashing, exactly as spec section 4.3.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'canonical_json.dart';

/// `hash(record) = hex(SHA-256(canonical(record including "sig")))`.
///
/// [recordJson] must be the full record, `sig` included — this is what a
/// following record's `prevHash` must match (the hash chain, spec section
/// 4.3), and what proves the record hasn't been altered since it was hashed.
String recordHash(Map<String, dynamic> recordJson) {
  final bytes = utf8.encode(canonicalJson(recordJson));
  return sha256.convert(bytes).toString();
}
