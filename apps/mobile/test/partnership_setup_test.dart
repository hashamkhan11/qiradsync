import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/onboarding/partnership_setup.dart';
import 'package:mobile/storage/record_store.dart';
import 'package:path/path.dart' as p;
import 'package:qirad_core/qirad_core.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  late Directory dir;
  late RecordStore store;
  late Ed25519KeyPair investor;
  late Ed25519KeyPair manager;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('qirad_setup_test');
    store = await RecordStore.open(
      factory: databaseFactoryFfi,
      path: p.join(dir.path, 'records.db'),
    );
    investor = await generateEd25519KeyPair();
    manager = await generateEd25519KeyPair();
  });

  tearDown(() async {
    await store.close();
    await dir.delete(recursive: true);
  });

  test(
    'creates a partnership with the create record saved and pinned',
    () async {
      final id = await createPartnership(
        investorKeys: investor,
        managerKey: manager.publicKeyBase64Url,
        investorPercent: 60,
        store: store,
      );

      expect(store.partnerships, [id]);
      final texts = await store.savedTexts(id);
      expect(texts, hasLength(1));

      final saved = jsonDecode(texts.single) as Map<String, dynamic>;
      expect(saved['type'], 'partnership_create');
      expect(saved['id'], id);
      expect(saved['partnership'], id);
      expect(saved['author'], investor.publicKeyBase64Url);
      expect(saved['body'], {
        'investor': investor.publicKeyBase64Url,
        'manager': manager.publicKeyBase64Url,
        'ratio': {'investor': 60, 'manager': 40},
        'currency': 'PKR',
      });
    },
  );

  test('the new id is a lowercase UUID v4 (spec 3)', () async {
    final id = await createPartnership(
      investorKeys: investor,
      managerKey: manager.publicKeyBase64Url,
      investorPercent: 60,
      store: store,
    );

    expect(
      id,
      matches(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ),
      ),
    );
  });

  test('two creates on one phone give two different partnerships', () async {
    final first = await createPartnership(
      investorKeys: investor,
      managerKey: manager.publicKeyBase64Url,
      investorPercent: 60,
      store: store,
    );
    final second = await createPartnership(
      investorKeys: investor,
      managerKey: manager.publicKeyBase64Url,
      investorPercent: 50,
      store: store,
    );

    expect(second, isNot(first));
    expect(store.partnerships, hasLength(2));
  });

  test(
    'a manager key that is not canonical is refused, and nothing is saved',
    () async {
      await expectLater(
        createPartnership(
          investorKeys: investor,
          managerKey: 'not-a-key',
          investorPercent: 60,
          store: store,
        ),
        throwsArgumentError,
      );

      expect(store.partnerships, isEmpty);
    },
  );

  test('the investor cannot name its own key as the manager', () async {
    await expectLater(
      createPartnership(
        investorKeys: investor,
        managerKey: investor.publicKeyBase64Url,
        investorPercent: 60,
        store: store,
      ),
      throwsArgumentError,
    );

    expect(store.partnerships, isEmpty);
  });

  test('a ratio outside 0 to 100 percent is refused', () async {
    for (final percent in [-1, 101]) {
      await expectLater(
        createPartnership(
          investorKeys: investor,
          managerKey: manager.publicKeyBase64Url,
          investorPercent: percent,
          store: store,
        ),
        throwsRangeError,
      );
    }

    expect(store.partnerships, isEmpty);
  });

  group('a create is saved all together or not at all', () {
    /// A create signed by someone who is not the pinned investor.
    Future<String> forgedCreate(String id) async {
      final attacker = await generateEd25519KeyPair();
      final unsigned = Record(
        v: 1,
        id: id,
        partnership: id,
        author: attacker.publicKeyBase64Url,
        seq: 1,
        prevHash: '0' * 64,
        type: 'partnership_create',
        body: {
          'investor': attacker.publicKeyBase64Url,
          'manager': manager.publicKeyBase64Url,
          'ratio': {'investor': 60, 'manager': 40},
          'currency': 'PKR',
        },
        refersTo: null,
        note: '',
        time: '2026-10-04T10:00:00Z',
        sig: '',
      );
      return canonicalJson((await signRecord(unsigned, attacker)).toJson());
    }

    test(
      'a refused create leaves no partnership, no pins and no record',
      () async {
        const id = 'a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d';
        final outcome = await store.startPartnership(
          id: id,
          investorKey: investor.publicKeyBase64Url,
          managerKey: manager.publicKeyBase64Url,
          createText: await forgedCreate(id),
        );

        expect(outcome, isNot(ReceiveOutcome.accepted));
        expect(store.partnerships, isEmpty);
        await store.close();

        // Reopen the file, so the test reads what is on disk, not memory.
        store = await RecordStore.open(
          factory: databaseFactoryFfi,
          path: p.join(dir.path, 'records.db'),
        );
        expect(store.partnerships, isEmpty);
      },
    );

    test('after a refused create, the same id can still be started', () async {
      const id = 'a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d';
      await store.startPartnership(
        id: id,
        investorKey: investor.publicKeyBase64Url,
        managerKey: manager.publicKeyBase64Url,
        createText: await forgedCreate(id),
      );

      final id2 = await createPartnership(
        investorKeys: investor,
        managerKey: manager.publicKeyBase64Url,
        investorPercent: 60,
        store: store,
      );

      expect(store.partnerships, [id2]);
    });
  });
}
