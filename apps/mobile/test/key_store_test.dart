import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/storage/key_store.dart';
import 'package:qirad_core/qirad_core.dart';

import 'support/fake_secret_store.dart';

void main() {
  late FakeSecretStore secrets;
  late KeyStore store;

  setUp(() {
    secrets = FakeSecretStore();
    store = KeyStore(secrets);
  });

  test('a saved key loads back with the same public key', () async {
    final pair = await generateEd25519KeyPair();
    await store.save(pair);

    final loaded = await store.load();

    expect(loaded, isNotNull);
    expect(loaded!.publicKeyBase64Url, pair.publicKeyBase64Url);
    expect(loaded.privateKeyBytes, pair.privateKeyBytes);
  });

  test(
    'nothing saved gives null, so onboarding knows to create a key',
    () async {
      expect(await store.load(), isNull);
    },
  );

  test('saving again replaces the key', () async {
    final first = await generateEd25519KeyPair();
    final second = await generateEd25519KeyPair();
    await store.save(first);
    await store.save(second);

    final loaded = await store.load();

    expect(loaded!.publicKeyBase64Url, second.publicKeyBase64Url);
  });

  test(
    'loadOrCreate makes a key once, then gives the same key again',
    () async {
      final first = await store.loadOrCreate();
      final second = await store.loadOrCreate();

      expect(second.publicKeyBase64Url, first.publicKeyBase64Url);
      expect(secrets.values.length, 1);
    },
  );

  test('only the seed is written, under one name', () async {
    final pair = await generateEd25519KeyPair();
    await store.save(pair);

    expect(secrets.values.keys, ['qirad.private_key.v1']);
    expect(
      secrets.values.values.single,
      isNot(contains(pair.publicKeyBase64Url)),
    );
  });
}
