import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/storage/record_store.dart';
import 'package:path/path.dart' as p;
import 'package:qirad_core/qirad_core.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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

  /// The partnership_create text, with a non-ASCII note.
  Future<String> createText() async {
    final unsigned = Record(
      v: 1,
      id: 'p1',
      partnership: 'p1',
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
  }) async {
    final unsigned = Record(
      v: 1,
      id: id,
      partnership: 'p1',
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
  Future<String> approveText({required String id, required int seq}) async {
    final unsigned = Record(
      v: 1,
      id: id,
      partnership: 'p1',
      author: manager.publicKeyBase64Url,
      seq: seq,
      prevHash: '0' * 64,
      type: 'approve',
      body: const {},
      refersTo: 'invest-2',
      note: '',
      time: '2026-10-03T10:00:00Z',
      sig: '',
    );
    return canonicalJson((await signRecord(unsigned, manager)).toJson());
  }

  test('an accepted record is saved with its exact text', () async {
    final store = await openStore();
    final text = await createText();

    expect(await store.receive(text), ReceiveOutcome.accepted);
    expect(await store.savedTexts(), [text]);
    await store.close();
  });

  test('a repeated text is saved once', () async {
    final store = await openStore();
    final text = await createText();

    await store.receive(text);
    expect(await store.receive(text), ReceiveOutcome.duplicateIgnored);
    expect(await store.savedTexts(), hasLength(1));
    await store.close();
  });

  test('a rejected text is never saved', () async {
    final store = await openStore();
    final text = await createText();
    // Valid JSON, but not canonical: one extra space after the opening brace.
    final notCanonical = '{ ${text.substring(1)}';

    expect(
      await store.receive(notCanonical),
      ReceiveOutcome.rejectedNotCanonical,
    );
    expect(await store.savedTexts(), isEmpty);
    await store.close();
  });

  test('after reopening, the ledger is rebuilt from the saved texts', () async {
    final store = await openStore();
    final create = await createText();
    final invest = await investText(id: 'invest-2', seq: 2, prevText: create);
    await store.receive(create);
    await store.receive(invest);
    await store.close();

    final reopened = await openStore();
    expect(reopened.validator.ledger.records.map((r) => r.id), [
      'p1',
      'invest-2',
    ]);
    await reopened.close();
  });

  test(
    'a record that arrives early waits in the pending buffer, then is released',
    () async {
      final store = await openStore();
      final create = await createText();
      final invest2 = await investText(
        id: 'invest-2',
        seq: 2,
        prevText: create,
      );
      final invest3 = await investText(
        id: 'invest-3',
        seq: 3,
        prevText: invest2,
      );

      await store.receive(create);
      expect(await store.receive(invest3), ReceiveOutcome.pending);
      await store.close();

      // The pending record survives a restart, and arrives when seq 2 does.
      final reopened = await openStore();
      expect(reopened.validator.pendingRecords.map((r) => r.id), ['invest-3']);
      expect(await reopened.receive(invest2), ReceiveOutcome.accepted);
      expect(reopened.validator.ledger.records.map((r) => r.id), [
        'p1',
        'invest-2',
        'invest-3',
      ]);
      await reopened.close();
    },
  );

  test(
    'two versions at the same position are both kept and the author is flagged after a restart',
    () async {
      final store = await openStore();
      final create = await createText();
      await store.receive(create);
      final approveA = await approveText(id: 'approve-5a', seq: 5);
      final approveB = await approveText(id: 'approve-5b', seq: 5);
      await store.receive(approveA);
      expect(await store.receive(approveB), ReceiveOutcome.equivocating);
      await store.close();

      final reopened = await openStore();
      expect(await reopened.savedTexts(), containsAll([approveA, approveB]));
      expect(reopened.validator.equivocatingFromSeq, {
        manager.publicKeyBase64Url: 5,
      });
      await reopened.close();
    },
  );

  test('the database refuses UPDATE and DELETE', () async {
    final store = await openStore();
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
