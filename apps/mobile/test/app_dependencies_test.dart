import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/app_dependencies.dart';
import 'package:mobile/onboarding/partnership_setup.dart';
import 'package:mobile/storage/key_store.dart';
import 'package:mobile/storage/record_store.dart';
import 'package:mobile/sync/relay_url.dart';
import 'package:path/path.dart' as p;
import 'package:qirad_core/qirad_core.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// An in-memory stand-in for the platform's secure storage, so this test
/// never touches the real keychain.
class _FakeSecretStore implements SecretStore {
  final _values = <String, String>{};

  @override
  Future<String?> read(String name) async => _values[name];

  @override
  Future<void> write(String name, String value) async {
    _values[name] = value;
  }
}

void main() {
  setUpAll(sqfliteFfiInit);

  late Directory dir;
  late RecordStore store;
  late Ed25519KeyPair keys;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('qirad_app_deps_test');
    store = await RecordStore.open(
      factory: databaseFactoryFfi,
      path: p.join(dir.path, 'records.db'),
    );
    keys = await generateEd25519KeyPair();
  });

  tearDown(() async {
    await store.close();
    await dir.delete(recursive: true);
  });

  test('create refuses a relay url that is not allowed', () {
    expect(
      () => AppDependencies.create(
        relayUrl: 'http://relay.example.com',
        debug: false,
        store: store,
        keys: keys,
        secrets: _FakeSecretStore(),
      ),
      throwsA(isA<RelayUrlError>()),
    );
  });

  test('create wires every dependency to the given relay url', () {
    final deps = AppDependencies.create(
      relayUrl: 'https://relay.example.com',
      debug: false,
      store: store,
      keys: keys,
      secrets: _FakeSecretStore(),
    );

    expect(deps.relay.baseUrl, 'https://relay.example.com');
    expect(deps.session.relay, same(deps.relay));
    expect(deps.syncRunner.relay, same(deps.relay));
    expect(deps.store, same(store));
    expect(deps.keys, same(keys));
  });

  test('writerFor returns the same instance for the same partnership, '
      'including after onboarding adds its own records', () async {
    final deps = AppDependencies.create(
      relayUrl: 'https://relay.example.com',
      debug: false,
      store: store,
      keys: keys,
      secrets: _FakeSecretStore(),
    );
    final manager = await generateEd25519KeyPair();
    final partnership = await createPartnership(
      investorKeys: keys,
      managerKey: manager.publicKeyBase64Url,
      investorPercent: 60,
      store: store,
    );

    final first = deps.writerFor(partnership);
    // "Onboarding completes" and the app later asks again, maybe from a
    // different screen; it must still get back the one writer, never a
    // second one that could race it (spec 7.4).
    final second = deps.writerFor(partnership);

    expect(second, same(first));
  });
}
