import 'package:qirad_core/qirad_core.dart';
import 'package:test/test.dart';

void main() {
  group('recordHash', () {
    test('matches a known hash vector (computed independently with sha256sum)', () {
      // This exact JSON, byte for byte, was hashed outside Dart (coreutils
      // `sha256sum`) to get the expected value below. If this test ever
      // fails, the bug is in canonicalJson or recordHash, not the vector.
      final json = {
        'v': 1,
        'id': '11111111-1111-4111-8111-111111111111',
        'partnership': '11111111-1111-4111-8111-111111111111',
        'author': 'author-pubkey-base64url',
        'seq': 1,
        'prevHash': '0' * 64,
        'type': 'partnership_create',
        'body': {'name': 'Test Mudaraba'},
        'refersTo': null,
        'note': '',
        'time': '2026-10-02T10:15:00Z',
        'sig': 'sig-base64url',
      };

      expect(
        recordHash(json),
        'fa9993cb664e5ca1b8576d0a9bcfd197ee8f69e6bb3919b7ce0cf7fc271d176b',
      );
    });

    test('hashing is sensitive to field order in the input map (output is not)', () {
      final a = {'v': 1, 'id': 'x'};
      final b = {'id': 'x', 'v': 1};

      expect(recordHash(a), recordHash(b));
    });

    test('changing any field changes the hash', () {
      final original = {'v': 1, 'id': 'x', 'note': 'original'};
      final changed = {'v': 1, 'id': 'x', 'note': 'changed'};

      expect(recordHash(original), isNot(recordHash(changed)));
    });
  });
}
