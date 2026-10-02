import 'package:qirad_core/qirad_core.dart';
import 'package:test/test.dart';

Record _unsigned(String author) {
  return Record(
    v: 1,
    id: '11111111-1111-4111-8111-111111111111',
    partnership: '11111111-1111-4111-8111-111111111111',
    author: author,
    seq: 1,
    prevHash: '0' * 64,
    type: 'partnership_create',
    body: const {'name': 'Test Mudaraba'},
    refersTo: null,
    note: '',
    time: '2026-10-02T10:15:00Z',
    sig: '', // placeholder — signRecord ignores and replaces it
  );
}

void main() {
  group('generateEd25519KeyPair', () {
    test('produces a 43-character base64url public key, as spec section 2 requires', () async {
      final keyPair = await generateEd25519KeyPair();

      expect(keyPair.publicKeyBase64Url.length, 43);
      expect(keyPair.publicKeyBase64Url, isNot(contains('=')));
    });

    test('two generated key pairs are different', () async {
      final a = await generateEd25519KeyPair();
      final b = await generateEd25519KeyPair();

      expect(a.publicKeyBase64Url, isNot(b.publicKeyBase64Url));
    });
  });

  group('signRecord / verifyRecord', () {
    test('a freshly signed record verifies', () async {
      final keyPair = await generateEd25519KeyPair();
      final signed = await signRecord(_unsigned(keyPair.publicKeyBase64Url), keyPair);

      expect(await verifyRecord(signed), isTrue);
    });

    test('changing any field after signing makes verification fail', () async {
      final keyPair = await generateEd25519KeyPair();
      final signed = await signRecord(_unsigned(keyPair.publicKeyBase64Url), keyPair);

      final tampered = signed.copyWith(note: 'changed after signing');

      expect(await verifyRecord(tampered), isFalse);
    });

    test('a signature from the wrong key pair fails verification', () async {
      final keyPair = await generateEd25519KeyPair();
      final otherKeyPair = await generateEd25519KeyPair();

      // Signed by otherKeyPair, but author claims to be keyPair.
      final signed = await signRecord(_unsigned(keyPair.publicKeyBase64Url), otherKeyPair);

      expect(await verifyRecord(signed), isFalse);
    });

    test('a garbage signature fails verification instead of throwing', () async {
      final keyPair = await generateEd25519KeyPair();
      final signed = await signRecord(_unsigned(keyPair.publicKeyBase64Url), keyPair);

      final garbled = signed.copyWith(sig: 'not-valid-base64url!!!');

      expect(await verifyRecord(garbled), isFalse);
    });

    test('a garbage author fails verification instead of throwing', () async {
      final keyPair = await generateEd25519KeyPair();
      final signed = await signRecord(_unsigned(keyPair.publicKeyBase64Url), keyPair);

      final garbled = signed.copyWith(author: 'not-a-real-key');

      expect(await verifyRecord(garbled), isFalse);
    });
  });
}
