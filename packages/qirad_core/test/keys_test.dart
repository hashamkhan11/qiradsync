import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:qirad_core/qirad_core.dart';
import 'package:test/test.dart';

void main() {
  group('ed25519KeyPairFromSeed', () {
    test('gives the same public key as the relay for the same seed', () async {
      // The seed is the same test key the relay fixture uses ("investor").
      // Its public key is the one PHP computed in testdata/relay_equivocation_sync.json.
      final seed = sha256
          .convert(utf8.encode('qiradsync test key: investor'))
          .bytes;

      final pair = await ed25519KeyPairFromSeed(seed);

      expect(
        pair.publicKeyBase64Url,
        'VmSPAhKyuAy4gr_6kPOSyVQUW4bojvHOSDKEv_K0SWU',
      );
      expect(pair.privateKeyBytes, seed);
    });

    test('a generated key pair restores to the same public key', () async {
      final original = await generateEd25519KeyPair();

      final restored = await ed25519KeyPairFromSeed(original.privateKeyBytes);

      expect(restored.publicKeyBytes, original.publicKeyBytes);
    });

    test('a seed that is not 32 bytes is refused', () async {
      await expectLater(
        ed25519KeyPairFromSeed(List.filled(31, 0)),
        throwsArgumentError,
      );
    });
  });

  group('isCanonicalPublicKey', () {
    test('accepts the canonical spelling of a 32-byte key', () async {
      final pair = await ed25519KeyPairFromSeed(List<int>.filled(32, 7));
      expect(isCanonicalPublicKey(pair.publicKeyBase64Url), isTrue);
    });

    test('refuses a key of the wrong length', () {
      expect(isCanonicalPublicKey('abc'), isFalse);
      expect(isCanonicalPublicKey('A' * 44), isFalse);
    });

    test('refuses characters that are not base64url', () {
      expect(isCanonicalPublicKey('+' * 43), isFalse);
      expect(isCanonicalPublicKey('=' * 43), isFalse);
    });

    test('refuses a non-canonical spelling of a real key', () async {
      // 43 characters carry 258 bits, but a key has only 256. The last
      // character's 2 spare low bits must be zero. A letter with those bits
      // set decodes to the same bytes, so it would be a second spelling of
      // the same key, and it must be refused.
      const alphabet =
          'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
      final pair = await ed25519KeyPairFromSeed(List<int>.filled(32, 7));
      final prefix = pair.publicKeyBase64Url.substring(0, 42);
      final spare = [
        for (var i = 0; i < 64; i++)
          if (i % 4 != 0) alphabet[i],
      ];
      for (final last in spare) {
        expect(isCanonicalPublicKey(prefix + last), isFalse, reason: last);
      }
    });
  });
}
