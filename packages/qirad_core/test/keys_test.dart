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
}
