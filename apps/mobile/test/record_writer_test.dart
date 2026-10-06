import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/storage/record_store.dart';
import 'package:mobile/storage/record_writer.dart';
import 'package:path/path.dart' as p;
import 'package:qirad_core/qirad_core.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/test_ids.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  late Directory dir;
  late RecordStore store;
  late Ed25519KeyPair investor;
  late Ed25519KeyPair manager;
  late String partnership;

  // Each party's own records, in seq order. A record is always built on its
  // author's chain, the same way a phone builds it.
  late List<Record> investorChain;
  late List<Record> managerChain;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('qirad_writer_test');
    store = await RecordStore.open(
      factory: databaseFactoryFfi,
      path: p.join(dir.path, 'records.db'),
    );
    investor = await generateEd25519KeyPair();
    manager = await generateEd25519KeyPair();
    partnership = testId('partnership');
    investorChain = [];
    managerChain = [];
  });

  tearDown(() async {
    await store.close();
    await dir.delete(recursive: true);
  });

  /// Builds and signs the next record of [keys], and adds it to its chain.
  Future<Record> write(
    Ed25519KeyPair keys,
    List<Record> chain, {
    required String id,
    required String type,
    Map<String, dynamic> body = const {},
    String? refersTo,
  }) async {
    final unsigned = buildRecord(
      ledger: chain,
      author: keys.publicKeyBase64Url,
      partnership: partnership,
      id: testId(id),
      type: type,
      body: body,
      time: '2026-10-06T10:00:00Z',
      refersTo: refersTo,
    );
    final signed = await signRecord(unsigned, keys);
    chain.add(signed);
    return signed;
  }

  /// The investor's partnership_create, saved with the pins (spec 2.1).
  Future<void> startWithCreate() async {
    // A create's record id is its partnership id (spec 3), so it uses the
    // same name as the partnership.
    final create = await write(
      investor,
      investorChain,
      id: 'partnership',
      type: 'partnership_create',
      body: {
        'investor': investor.publicKeyBase64Url,
        'manager': manager.publicKeyBase64Url,
        'ratio': {'investor': 60, 'manager': 40},
        'currency': 'PKR',
      },
    );
    final outcome = await store.startPartnership(
      id: partnership,
      investorKey: investor.publicKeyBase64Url,
      managerKey: manager.publicKeyBase64Url,
      createText: canonicalJson(create.toJson()),
    );
    expect(outcome, ReceiveOutcome.accepted);
  }

  /// A manager settlement proposal with an empty cut (covers nothing). An empty
  /// cut is held and dominates the empty previous cut, so only the ordering
  /// rules are tested here.
  Future<Record> settlement(String id) => write(
    manager,
    managerChain,
    id: id,
    type: 'settlement',
    body: {
      'cut': {investor.publicKeyBase64Url: 0, manager.publicKeyBase64Url: 0},
    },
  );

  /// Saves one record from the other partner, as a sync would.
  Future<void> receive(Record record) async {
    final outcome = await store.receive(canonicalJson(record.toJson()));
    expect(outcome, ReceiveOutcome.accepted);
  }

  /// Saves the relay vector from a sync reply (spec 7.4, rule 2).
  Future<void> syncedAs({required int investorSeq, required int managerSeq}) =>
      store.saveRelayVector(partnership, {
        investor.publicKeyBase64Url: investorSeq,
        manager.publicKeyBase64Url: managerSeq,
      });

  RecordWriter writer() =>
      RecordWriter(keys: investor, partnership: partnership, store: store);

  group('RecordWriter (spec 7.4)', () {
    test('two concurrent answers give one record and no shared seq', () async {
      await startWithCreate();
      await receive(await settlement('s1'));
      await syncedAs(investorSeq: 1, managerSeq: 1);

      final results = await Future.wait([
        writer().answer(testId('s1'), approve: true),
        writer().answer(testId('s1'), approve: true),
      ]);

      final written = results.where((r) => r.record != null).toList();
      final refused = results.where((r) => r.refusal != null).toList();
      expect(written, hasLength(1));
      expect(refused.single.refusal, WriteRefusal.alreadyAnswered);

      // Every saved record of mine has its own seq: 1 (create) and 2 (answer).
      final mine = (await store.savedTexts(partnership))
          .map((t) => Record.fromJson(jsonDecode(t) as Map<String, dynamic>))
          .where((r) => r.author == investor.publicKeyBase64Url)
          .map((r) => r.seq)
          .toList();
      expect(mine, [1, 2]);
    });

    test(
      'an invalid early answer does not block a later valid one (spec 6.7)',
      () async {
        await startWithCreate();
        await receive(await settlement('s1'));
        await receive(await settlement('s2'));
        await syncedAs(investorSeq: 1, managerSeq: 2);

        // S2 before S1: the ordering rule makes this answer invalid.
        final early = await writer().answer(testId('s2'), approve: true);
        expect(early.record!.seq, 2);

        // S1 is valid, and it lets the next answer to S2 count.
        final s1 = await writer().answer(testId('s1'), approve: true);
        expect(s1.record!.seq, 3);

        final s2 = await writer().answer(testId('s2'), approve: true);
        expect(s2.record!.seq, 4);

        final validator = store.validatorFor(partnership);
        final decisions = decideApprovals(
          validator.usableRecords,
          partnershipKeys: validator.partnershipKeys!,
        );
        final decidedS2 = decisions.singleWhere(
          (d) => d.target.id == testId('s2'),
        );
        expect(decidedS2.status, DecisionStatus.active);
      },
    );

    test('a second valid answer to the same proposal is refused', () async {
      await startWithCreate();
      await receive(await settlement('s1'));
      await syncedAs(investorSeq: 1, managerSeq: 1);

      await writer().answer(testId('s1'), approve: true);
      final again = await writer().answer(testId('s1'), approve: false);

      expect(again.refusal, WriteRefusal.alreadyAnswered);
    });

    test(
      'a failed save leaves no record behind, so the retry takes the same seq',
      () async {
        await startWithCreate();
        await receive(await settlement('s1'));
        await syncedAs(investorSeq: 1, managerSeq: 1);

        // A second connection to the same file makes every insert fail. The
        // validator checked the record first, so it must be rebuilt after the
        // rollback, or the retry would clash with the record it still holds.
        // singleInstance: false gives a separate connection; by default sqflite
        // would hand back the store's own connection and close it here.
        final side = await databaseFactoryFfi.openDatabase(
          p.join(dir.path, 'records.db'),
          options: OpenDatabaseOptions(singleInstance: false),
        );
        await side.execute(
          "CREATE TRIGGER fail_insert BEFORE INSERT ON records "
          "BEGIN SELECT RAISE(ABORT, 'disk full'); END",
        );
        await expectLater(
          writer().answer(testId('s1'), approve: true),
          throwsA(anything),
        );
        await side.execute('DROP TRIGGER fail_insert');
        await side.close();

        final retry = await writer().answer(testId('s1'), approve: true);
        expect(retry.record!.seq, 2);
        expect(await store.savedTexts(partnership), hasLength(3));
      },
    );

    test('a store that was never synced refuses every write', () async {
      await startWithCreate();
      await receive(await settlement('s1'));

      final result = await writer().answer(testId('s1'), approve: true);

      expect(result.refusal, WriteRefusal.notSynced);
    });

    test('the relay holding seq 5 refuses a write on an empty store', () async {
      // The key is known, but nothing is saved yet: a restore or a new install.
      await store.addPartnership(
        partnership,
        investorKey: investor.publicKeyBase64Url,
        managerKey: manager.publicKeyBase64Url,
      );
      await syncedAs(investorSeq: 5, managerSeq: 0);

      final result = await writer().answer(testId('s1'), approve: true);

      expect(result.refusal, WriteRefusal.chainBehindRelay);
      expect(await store.savedTexts(partnership), isEmpty);
    });

    test(
      'after sync restores my seq 1 to 5, the next write is seq 6',
      () async {
        await startWithCreate();
        await receive(await settlement('s1'));
        await syncedAs(investorSeq: 5, managerSeq: 1);

        // Only the create is held, so the relay's seq 5 blocks the write.
        final blocked = await writer().answer(testId('s1'), approve: true);
        expect(blocked.refusal, WriteRefusal.chainBehindRelay);

        // The sync brings back my records 2 to 5, and the write is allowed.
        for (var i = 2; i <= 5; i++) {
          await receive(
            await write(
              investor,
              investorChain,
              id: 'invest-$i',
              type: 'invest',
              body: const {'amount': 100},
            ),
          );
        }
        await syncedAs(investorSeq: 5, managerSeq: 1);

        final result = await writer().answer(testId('s1'), approve: true);
        expect(result.record!.seq, 6);
      },
    );
  });
}
