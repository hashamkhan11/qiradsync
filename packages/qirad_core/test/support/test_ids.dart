import 'package:qirad_core/qirad_core.dart';

/// Turns a readable name into a fixed UUID v4, so tests can say
/// `testId('invest-2')` where a record id is needed. Spec section 3 requires
/// every record id to be a lowercase UUID v4, so the names cannot be used raw.
///
/// The same name always gives the same id, on every run, so expected values
/// can be written by name. The id is a hash of the name with the UUID v4
/// version and variant bits set. The phones use random ids; this is for tests.
///
/// apps/mobile/test/support/test_ids.dart and relay/tests/Support/TestIds.php
/// use the same rule, so a name gives the same id in every package.
String testId(String name) {
  // recordHash is SHA-256 of the canonical JSON, so the input text is always
  // '{"testId":"<name>"}'. The PHP helper builds that same text.
  final hex = recordHash({'testId': name}).substring(0, 32).split('');
  hex[12] = '4'; // version 4
  hex[16] = '89ab'[int.parse(hex[16], radix: 16) % 4]; // variant 10xx
  final h = hex.join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}'
      '-${h.substring(16, 20)}-${h.substring(20)}';
}
