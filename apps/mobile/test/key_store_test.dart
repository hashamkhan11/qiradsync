import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/storage/key_store.dart';
import 'package:qirad_core/qirad_core.dart';

/// An in-memory stand-in for the platform store. It keeps values only for
/// the life of the test, and does not hide anything.
class FakeSecretStore implements SecretStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String name) async => values[name];

  @override
  Future<void> write(String name, String value) async => values[name] = value;
}

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
