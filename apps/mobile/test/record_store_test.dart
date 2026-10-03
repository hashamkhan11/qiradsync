import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/storage/record_store.dart';
import 'package:path/path.dart' as p;
import 'package:qirad_core/qirad_core.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'support/test_ids.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  late Directory dir;
  late String dbPath;
  late Ed25519KeyPair investor;
  late Ed25519KeyPair manager;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('qirad_store_test');
    dbPath = p.join(dir.path, 'records.db');
    investor = await generateEd25519KeyPair();
    manager = await generateEd25519KeyPair();
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  Future<RecordStore> openStore() =>
      RecordStore.open(factory: databaseFactoryFfi, path: dbPath);

  /// The partnership_create text, with a non-ASCII note. The partnership id
  /// is also the id of the create record, as in the app.
  Future<String> createText({String? partnership}) async {
    partnership ??= testId('p1');
    final unsigned = Record(
      v: 1,
      id: partnership,
      partnership: partnership,
      author: investor.publicKeyBase64Url,
      seq: 1,
      prevHash: '0' * 64,
      type: 'partnership_create',
      body: {
        'investor': investor.publicKeyBase64Url,
        'manager': manager.publicKeyBase64Url,
        'ratio': {'investor': 60, 'manager': 40},
        'currency': 'PKR',
      },
      refersTo: null,
      note: 'شراکت نامہ',
      time: '2026-10-03T10:00:00Z',
      sig: '',
    );
    return canonicalJson((await signRecord(unsigned, investor)).toJson());
  }

  /// A signed record that follows [prevText] in the investor's chain.
  Future<String> investText({
    required String id,
    required int seq,
    required String prevText,
    String? partnership,
  }) async {
    partnership ??= testId('p1');
    final unsigned = Record(
      v: 1,
      id: id,
      partnership: partnership,
      author: investor.publicKeyBase64Url,
      seq: seq,
      prevHash: recordHash(jsonDecode(prevText) as Map<String, dynamic>),
      type: 'invest',
      body: {'amount': 150000},
      refersTo: null,
      note: '',
      time: '2026-10-03T10:00:00Z',
      sig: '',
    );
    return canonicalJson((await signRecord(unsigned, investor)).toJson());
  }

  /// A manager's approve at a given seq. The manager can write any seq.
  Future<String> approveText({
    required String id,
    required int seq,
    String? partnership,
  }) async {
    partnership ??= testId('p1');
    final unsigned = Record(
      v: 1,
      id: id,
      partnership: partnership,
      author: manager.publicKeyBase64Url,
      seq: seq,
      prevHash: '0' * 64,
      type: 'approve',
      body: const {},
      refersTo: testId('invest-2'),
      note: '',
      time: '2026-10-03T10:00:00Z',
      sig: '',
    );
    return canonicalJson((await signRecord(unsigned, manager)).toJson());
  }

  test('an accepted record is saved with its exact text', () async {
    final store = await openStore();
    await store.addPartnership(
      testId('p1'),
      investorKey: investor.publicKeyBase64Url,
      managerKey: manager.publicKeyBase64Url,
    );
    final text = await createText();

    expect(await store.receive(text), ReceiveOutcome.accepted);
    expect(await store.savedTexts(testId('p1')), [text]);
    await store.close();
  });

  test('a repeated text is saved once', () async {
    final store = await openStore();
    await store.addPartnership(
      testId('p1'),
      investorKey: investor.publicKeyBase64Url,
      managerKey: manager.publicKeyBase64Url,
    );
    final text = await createText();

    await store.receive(text);
    expect(await store.receive(text), ReceiveOutcome.duplicateIgnored);
    expect(await store.savedTexts(testId('p1')), hasLength(1));
    await store.close();
  });

  test('a rejected text is never saved', () async {
    final store = await openStore();
    await store.addPartnership(
      testId('p1'),
      investorKey: investor.publicKeyBase64Url,
      managerKey: manager.publicKeyBase64Url,
    );
    final text = await createText();
    // Valid JSON, but not canonical: one extra space after the opening brace.
    final notCanonical = '{ ${text.substring(1)}';

    expect(
      await store.receive(notCanonical),
      ReceiveOutcome.rejectedNotCanonical,
    );
    expect(await store.savedTexts(testId('p1')), isEmpty);
    await store.close();
  });

  test('after reopening, the ledger is rebuilt from the saved texts', () async {
    final store = await openStore();
    await store.addPartnership(
      testId('p1'),
      investorKey: investor.publicKeyBase64Url,
      managerKey: manager.publicKeyBase64Url,
    );
    final create = await createText();
    final invest = await investText(id: testId('invest-2'), seq: 2, prevText: create);
    await store.receive(create);
    await store.receive(invest);
    await store.close();

    final reopened = await openStore();
    expect(reopened.validatorFor(testId('p1')).ledger.records.map((r) => r.id), [
      testId('p1'),
      testId('invest-2'),
    ]);
    expect(reopened.versionVector(testId('p1')), {investor.publicKeyBase64Url: 2});
    await reopened.close();
  });

  test(
    'a record that arrives early waits in the pending buffer, then is released',
    () async {
      final store = await openStore();
      await store.addPartnership(
        testId('p1'),
        investorKey: investor.publicKeyBase64Url,
        managerKey: manager.publicKeyBase64Url,
      );
      final create = await createText();
      final invest2 = await investText(
        id: testId('invest-2'),
        seq: 2,
        prevText: create,
      );
      final invest3 = await investText(
        id: testId('invest-3'),
        seq: 3,
        prevText: invest2,
      );

      await store.receive(create);
      expect(await store.receive(invest3), ReceiveOutcome.pending);
      await store.close();

      // The pending record survives a restart, and arrives when seq 2 does.
      final reopened = await openStore();
      expect(reopened.validatorFor(testId('p1')).pendingRecords.map((r) => r.id), [
        testId('invest-3'),
      ]);
      expect(await reopened.receive(invest2), ReceiveOutcome.accepted);
      expect(reopened.validatorFor(testId('p1')).ledger.records.map((r) => r.id), [
        testId('p1'),
        testId('invest-2'),
        testId('invest-3'),
      ]);
      await reopened.close();
    },
  );

  test(
    'two versions at the same position are both kept and the author is flagged after a restart',
    () async {
      final store = await openStore();
      await store.addPartnership(
        testId('p1'),
        investorKey: investor.publicKeyBase64Url,
        managerKey: manager.publicKeyBase64Url,
      );
      final create = await createText();
      await store.receive(create);
      final approveA = await approveText(id: testId('approve-5a'), seq: 5);
      final approveB = await approveText(id: testId('approve-5b'), seq: 5);
      await store.receive(approveA);
      expect(await store.receive(approveB), ReceiveOutcome.equivocating);
      await store.close();

      final reopened = await openStore();
      expect(
        await reopened.savedTexts(testId('p1')),
        containsAll([approveA, approveB]),
      );
      expect(reopened.validatorFor(testId('p1')).equivocatingFromSeq, {
        manager.publicKeyBase64Url: 5,
      });
      await reopened.close();
    },
  );

  test(
    'a text for an unregistered partnership is refused and not stored',
    () async {
      final store = await openStore();
      await store.addPartnership(
        testId('p1'),
        investorKey: investor.publicKeyBase64Url,
        managerKey: manager.publicKeyBase64Url,
      );
      final stranger = await createText(partnership: testId('p9'));

      expect(await store.receive(stranger), ReceiveOutcome.rejectedMembership);
      expect(store.partnerships, [testId('p1')]);
      expect(() => store.savedTexts(testId('p9')), throwsStateError);
      await store.close();

      // Nothing was written for p9, even after a restart.
      final reopened = await openStore();
      expect(reopened.partnerships, [testId('p1')]);
      expect(await reopened.savedTexts(testId('p1')), isEmpty);
      await reopened.close();
    },
  );

  test('registering a partnership survives a restart', () async {
    final store = await openStore();
    await store.addPartnership(
      testId('p1'),
      investorKey: investor.publicKeyBase64Url,
      managerKey: manager.publicKeyBase64Url,
    );
    await store.addPartnership(
      testId('p1'),
      investorKey: investor.publicKeyBase64Url,
      managerKey: manager.publicKeyBase64Url,
    ); // Calling it again changes nothing.
    await store.close();

    final reopened = await openStore();
    expect(reopened.partnerships, [testId('p1')]);
    await reopened.close();
  });

  test(
    'two registered partnerships keep their records and vectors separate',
    () async {
      final store = await openStore();
      await store.addPartnership(
        testId('p1'),
        investorKey: investor.publicKeyBase64Url,
        managerKey: manager.publicKeyBase64Url,
      );
      await store.addPartnership(
        testId('p2'),
        investorKey: investor.publicKeyBase64Url,
        managerKey: manager.publicKeyBase64Url,
      );

      final create1 = await createText();
      final invest1 = await investText(
        id: testId('invest-1-2'),
        seq: 2,
        prevText: create1,
      );
      final create2 = await createText(partnership: testId('p2'));
      // Seq 2 in p2 is valid on its own chain, even though p1 also has seq 2.
      final invest2 = await investText(
        id: testId('invest-2-2'),
        seq: 2,
        prevText: create2,
        partnership: testId('p2'),
      );

      for (final text in [create1, invest1, create2, invest2]) {
        expect(await store.receive(text), ReceiveOutcome.accepted);
      }

      expect(await store.savedTexts(testId('p1')), [create1, invest1]);
      expect(await store.savedTexts(testId('p2')), [create2, invest2]);
      expect(store.versionVector(testId('p1')), {investor.publicKeyBase64Url: 2});
      expect(store.versionVector(testId('p2')), {investor.publicKeyBase64Url: 2});
      expect(store.validatorFor(testId('p1')).ledger.records.map((r) => r.id), [
        testId('p1'),
        testId('invest-1-2'),
      ]);
      expect(store.validatorFor(testId('p2')).ledger.records.map((r) => r.id), [
        testId('p2'),
        testId('invest-2-2'),
      ]);
      await store.close();
    },
  );

  test(
    'savedTextsFrom returns one author from a seq on, in seq order',
    () async {
      final store = await openStore();
      await store.addPartnership(
        testId('p1'),
        investorKey: investor.publicKeyBase64Url,
        managerKey: manager.publicKeyBase64Url,
      );
      final create = await createText();
      final invest2 = await investText(
        id: testId('invest-2'),
        seq: 2,
        prevText: create,
      );
      final invest3 = await investText(
        id: testId('invest-3'),
        seq: 3,
        prevText: invest2,
      );
      await store.receive(create);
      await store.receive(invest2);
      await store.receive(invest3);

      expect(
        await store.savedTextsFrom(
          testId('p1'),
          author: investor.publicKeyBase64Url,
          fromSeq: 2,
        ),
        [invest2, invest3],
      );
      expect(
        await store.savedTextsFrom(
          testId('p1'),
          author: manager.publicKeyBase64Url,
          fromSeq: 1,
        ),
        isEmpty,
      );
      await store.close();
    },
  );

  test(
    'a forged create arriving first is refused, then the real create is accepted',
    () async {
      final store = await openStore();
      await store.addPartnership(
        testId('p1'),
        investorKey: investor.publicKeyBase64Url,
        managerKey: manager.publicKeyBase64Url,
      );
      // The attacker signs a create with their own key, and names the real
      // manager. Only the pinned investor key can refuse it.
      final attacker = await generateEd25519KeyPair();
      final forgedUnsigned = Record(
        v: 1,
        id: testId('p1'),
        partnership: testId('p1'),
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
        time: '2026-10-03T10:00:00Z',
        sig: '',
      );
      final forged = canonicalJson(
        (await signRecord(forgedUnsigned, attacker)).toJson(),
      );

      expect(await store.receive(forged), ReceiveOutcome.rejectedMembership);
      expect(await store.savedTexts(testId('p1')), isEmpty);

      final real = await createText();
      expect(await store.receive(real), ReceiveOutcome.accepted);
      expect(await store.savedTexts(testId('p1')), [real]);
      await store.close();
    },
  );

  test(
    'a create naming another manager is refused, even after a restart',
    () async {
      final store = await openStore();
      await store.addPartnership(
        testId('p1'),
        investorKey: investor.publicKeyBase64Url,
        managerKey: manager.publicKeyBase64Url,
      );
      await store.close();

      // The pins were saved, so a restart still refuses the wrong manager.
      final reopened = await openStore();
      final otherManager = await generateEd25519KeyPair();
      final wrongManagerUnsigned = Record(
        v: 1,
        id: testId('p1'),
        partnership: testId('p1'),
        author: investor.publicKeyBase64Url,
        seq: 1,
        prevHash: '0' * 64,
        type: 'partnership_create',
        body: {
          'investor': investor.publicKeyBase64Url,
          'manager': otherManager.publicKeyBase64Url,
          'ratio': {'investor': 60, 'manager': 40},
          'currency': 'PKR',
        },
        refersTo: null,
        note: '',
        time: '2026-10-03T10:00:00Z',
        sig: '',
      );
      final wrongManager = canonicalJson(
        (await signRecord(wrongManagerUnsigned, investor)).toJson(),
      );

      expect(
        await reopened.receive(wrongManager),
        ReceiveOutcome.rejectedMembership,
      );
      expect(await reopened.savedTexts(testId('p1')), isEmpty);
      await reopened.close();
    },
  );

  test('registering again with other keys throws', () async {
    final store = await openStore();
    await store.addPartnership(
      testId('p1'),
      investorKey: investor.publicKeyBase64Url,
      managerKey: manager.publicKeyBase64Url,
    );
    final stranger = await generateEd25519KeyPair();

    await expectLater(
      store.addPartnership(
        testId('p1'),
        investorKey: stranger.publicKeyBase64Url,
        managerKey: manager.publicKeyBase64Url,
      ),
      throwsStateError,
    );
    await store.close();
  });

  test('the database refuses UPDATE and DELETE', () async {
    final store = await openStore();
    await store.addPartnership(
      testId('p1'),
      investorKey: investor.publicKeyBase64Url,
      managerKey: manager.publicKeyBase64Url,
    );
    await store.receive(await createText());
    await store.close();

    // A second connection, so the triggers are tested in the file itself.
    final db = await databaseFactoryFfi.openDatabase(dbPath);
    await expectLater(
      db.update('records', {'text': 'changed'}),
      throwsA(isA<DatabaseException>()),
    );
    await expectLater(db.delete('records'), throwsA(isA<DatabaseException>()));
    await db.close();
  });
}
