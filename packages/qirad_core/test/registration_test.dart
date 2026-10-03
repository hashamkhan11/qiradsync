import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:qirad_core/qirad_core.dart';
import 'package:test/test.dart';

void main() {
  late Ed25519KeyPair device;
  late Ed25519KeyPair other;
  const nonce = 'nonce-for-tests-0123456789abcdefghijk';

  setUp(() async {
    device = await generateEd25519KeyPair();
    other = await generateEd25519KeyPair();
  });

  test('a signature from the right key and nonce verifies', () async {
    final signature = await signRegistrationChallenge(device, nonce);

    expect(
      await verifyRegistrationChallenge(
        publicKey: device.publicKeyBase64Url,
        nonce: nonce,
        signature: signature,
      ),
      isTrue,
    );
  });

  test(
    'a signature over the bare nonce does not verify (domain separation)',
    () async {
      // Sign the nonce with no prefix, straight from cryptography. The relay
      // must refuse this, so the verifier must refuse it too.
      final cryptoPair = await Ed25519().newKeyPairFromSeed(
        device.privateKeyBytes,
      );
      final bare = await Ed25519().sign(
        utf8.encode(nonce),
        keyPair: cryptoPair,
      );

      expect(
        await verifyRegistrationChallenge(
          publicKey: device.publicKeyBase64Url,
          nonce: nonce,
          signature: encodeBase64UrlNoPadding(bare.bytes),
        ),
        isFalse,
      );
    },
  );

  test('a signature for one nonce does not verify for another', () async {
    final signature = await signRegistrationChallenge(device, nonce);

    expect(
      await verifyRegistrationChallenge(
        publicKey: device.publicKeyBase64Url,
        nonce: 'a-different-nonce',
        signature: signature,
      ),
      isFalse,
    );
  });

  test('a signature from another key does not verify', () async {
    final signature = await signRegistrationChallenge(other, nonce);

    expect(
      await verifyRegistrationChallenge(
        publicKey: device.publicKeyBase64Url,
        nonce: nonce,
        signature: signature,
      ),
      isFalse,
    );
  });

  test('malformed input gives false, not an exception', () async {
    expect(
      await verifyRegistrationChallenge(
        publicKey: 'not base64 !!',
        nonce: nonce,
        signature: 'also bad',
      ),
      isFalse,
    );
  });
}
