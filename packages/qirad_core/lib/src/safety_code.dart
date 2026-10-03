import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'keys.dart';

/// The safety code both partners compare before a join is confirmed (spec 2.1).
///
/// Both phones compute it from both keys, in the same order: investor first,
/// then manager. The code is different for any swapped or changed key, so a
/// join code that was swapped on the way is caught by the comparison.
///
/// The text starts with a version label, so a later rule cannot give the same
/// digits as this one. Keys are checked first: two spellings of one key would
/// give two codes for one partnership.
String safetyCode({required String investorKey, required String managerKey}) {
  _checkKey(investorKey, 'investorKey');
  _checkKey(managerKey, 'managerKey');

  final text = utf8.encode('qiradsync-safety-v1:$investorKey:$managerKey');
  final digest = sha256.convert(text).bytes;

  // The first 16 bytes as one big-endian number, reduced to 24 digits. 2^128 is
  // far larger than 10^24, so the reduction is almost even across codes.
  var number = BigInt.zero;
  for (final byte in digest.take(16)) {
    number = (number << 8) | BigInt.from(byte);
  }
  final digits = (number % BigInt.from(10).pow(24)).toString().padLeft(24, '0');

  // Groups of 4 are easier to read aloud and to compare by eye.
  return [
    for (var i = 0; i < digits.length; i += 4) digits.substring(i, i + 4),
  ].join(' ');
}

/// Accepts only the canonical spelling of a 32-byte key: 43 characters that
/// decode to 32 bytes and encode back to the same text.
void _checkKey(String key, String name) {
  if (key.length != 43) {
    throw ArgumentError.value(
      key,
      name,
      'must be a 43-character base64url key',
    );
  }
  try {
    final bytes = decodeBase64UrlNoPadding(key);
    if (bytes.length != 32 || encodeBase64UrlNoPadding(bytes) != key) {
      throw ArgumentError.value(key, name, 'must be a canonical 32-byte key');
    }
  } on FormatException {
    throw ArgumentError.value(key, name, 'must be a canonical 32-byte key');
  }
}
