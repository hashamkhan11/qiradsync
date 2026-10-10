import 'dart:async';
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

  /// The investor's partnership_create, saved with the pins (spec 2.1), with
  /// no approve yet, so the partnership is still pending (spec section 5).
  Future<void> startWithUnapprovedCreate() async {
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

  /// [startWithUnapprovedCreate], then the manager's approve of it, so the
  /// partnership is active (spec section 5) and later proposals can be
  /// answered.
  Future<void> startWithCreate() async {
    await startWithUnapprovedCreate();
    final approveCreate = await write(
      manager,
      managerChain,
      id: 'approve-create',
      type: 'approve',
      refersTo: testId('partnership'),
    );
    expect(
      await store.receive(canonicalJson(approveCreate.toJson())),
      ReceiveOutcome.accepted,
    );
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

  RecordWriter writer() => RecordWriter.forTesting(
    keys: investor,
    partnership: partnership,
    store: store,
  );

  RecordWriter managerWriter() => RecordWriter.forTesting(
    keys: manager,
    partnership: partnership,
    store: store,
  );

  /// An unsaved investor approve of [targetId], built on the saved ledger.
  /// The screen builds the same kind of record to show its summary.
  Record previewApprove(String targetId) => buildRecord(
    ledger: store.validatorFor(partnership).usableRecords,
    author: investor.publicKeyBase64Url,
    partnership: partnership,
    id: testId('preview-$targetId'),
    type: 'approve',
    body: const {},
    time: '2026-10-06T10:00:00Z',
    refersTo: targetId,
  );

  /// The summary the user would be shown for settlement [proposal] now.
  SettlementConsent? previewSettlement(Record proposal) {
    final validator = store.validatorFor(partnership);
    return settlementConsent(
      validator.usableRecords,
      partnershipKeys: {
        investor.publicKeyBase64Url,
        manager.publicKeyBase64Url,
      },
      proposal: proposal,
      answer: previewApprove(proposal.id),
    );
  }

  /// The summary the user would be shown for withdrawal [request] now.
  WithdrawalConsent? previewWithdrawal(Record request) {
    final validator = store.validatorFor(partnership);
    return withdrawalConsent(
      validator.usableRecords,
      partnershipKeys: {
        investor.publicKeyBase64Url,
        manager.publicKeyBase64Url,
      },
      request: request,
      answer: previewApprove(request.id),
    );
  }

  /// The summary the user would be shown for budget [proposal] now.
  BudgetConsent? previewBudget(Record proposal) {
    final validator = store.validatorFor(partnership);
    return budgetConsent(
      validator.usableRecords,
      partnershipKeys: {
        investor.publicKeyBase64Url,
        manager.publicKeyBase64Url,
      },
      proposal: proposal,
    );
  }

  /// Saves an invest and a sale, then the manager's settlement S1 with a cut
  /// up to both of those records. S1 is pending until the investor answers it.
  Future<Record> settlementReady() async {
    await startWithCreate();
    final invest = await write(
      investor,
      investorChain,
      id: 'invest-1',
      type: 'invest',
      body: const {'amount': 100000},
    );
    await receive(invest);
    final sale = await write(
      manager,
      managerChain,
      id: 'sale-1',
      type: 'sale',
      body: const {'amount': 50000},
    );
    await receive(sale);
    // The cut reads each record's own seq, not a hand-counted number, so a
    // fixture change (like adding the manager's approve of the create)
    // cannot silently shift what this settlement covers.
    final s1 = await write(
      manager,
      managerChain,
      id: 's1',
      type: 'settlement',
      body: {
        'cut': {
          investor.publicKeyBase64Url: invest.seq,
          manager.publicKeyBase64Url: sale.seq,
        },
      },
    );
    await receive(s1);
    await syncedAs(investorSeq: 2, managerSeq: 1);
    return s1;
  }

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

    test('the writer refuses to answer S2 before S1 (spec 6.7)', () async {
      await startWithCreate();
      await receive(await settlement('s1'));
      await receive(await settlement('s2'));
      await syncedAs(investorSeq: 1, managerSeq: 2);

      // S2 before S1: the ordering rule makes this answer invalid. The app
      // never writes a record it already knows is invalid.
      final early = await writer().answer(testId('s2'), approve: true);

      expect(early.refusal, WriteRefusal.answerEarlierFirst);
      // create, approveCreate, s1 and s2: nothing new was saved.
      expect(await store.savedTexts(partnership), hasLength(4));
    });

    test('an invalid early answer, once on the ledger, does not block a later '
        'valid one (spec 6.7)', () async {
      await startWithCreate();
      await receive(await settlement('s1'));
      await receive(await settlement('s2'));
      await syncedAs(investorSeq: 1, managerSeq: 2);

      // A hand-built early answer to S2. The writer itself would refuse to
      // create this (see the test above); this stands in for a record that
      // reached the ledger some other way, so the "invalid answers are
      // evidence, not a block" rule still has a case to cover.
      final early = await write(
        investor,
        investorChain,
        id: 'early-s2',
        type: 'approve',
        refersTo: testId('s2'),
      );
      await receive(early);
      await syncedAs(investorSeq: 2, managerSeq: 2);

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
    });

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
        // create, approveCreate, s1 and the retried answer.
        expect(await store.savedTexts(partnership), hasLength(4));
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
      'answering anything but the create is refused while it is still pending',
      () async {
        // Spec section 5: until the create is active, the only write allowed
        // is the manager's own answer to it. A budget proposal made while
        // the create is still pending cannot be answered either.
        await startWithUnapprovedCreate();
        final budget = await write(
          investor,
          investorChain,
          id: 'budget-1',
          type: 'budget_proposal',
          body: {'grantee': manager.publicKeyBase64Url, 'amount': 100000},
        );
        await receive(budget);
        await syncedAs(investorSeq: 2, managerSeq: 0);

        final result = await RecordWriter.forTesting(
          keys: manager,
          partnership: partnership,
          store: store,
        ).answer(testId('budget-1'), approve: true);

        expect(result.refusal, WriteRefusal.partnershipNotActive);
        // create and budget: nothing new was saved.
        expect(await store.savedTexts(partnership), hasLength(2));
      },
    );

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

    test('a vector save waits for a write that is mid-build', () async {
      await store.addPartnership(
        partnership,
        investorKey: investor.publicKeyBase64Url,
        managerKey: manager.publicKeyBase64Url,
      );
      // A write that is held open inside its build step, so it is still in
      // the queue when the vector save is requested.
      final release = Completer<void>();
      final write = store.appendWith(partnership, (texts) async {
        await release.future;
        return null;
      });
      // Read the flag, not the database: a read would wait for the open
      // transaction, which is waiting for this test.
      var saved = false;
      final save = store
          .saveRelayVector(partnership, {investor.publicKeyBase64Url: 3})
          .then((_) => saved = true);

      await Future<void>.delayed(Duration.zero);
      expect(saved, isFalse);

      release.complete();
      await write;
      await save;
      expect(saved, isTrue);
      expect(await store.relayVectorFor(partnership), {
        investor.publicKeyBase64Url: 3,
      });
    });

    test('an approve whose shown summary still matches is written', () async {
      final s1 = await settlementReady();
      final shown = previewSettlement(s1);
      expect(shown, isNotNull);

      final result = await writer().answer(
        testId('s1'),
        approve: true,
        shownSettlement: shown,
      );

      expect(result.record, isNotNull);
      expect(result.record!.seq, 3);
    });

    test(
      'a summary changed between preview and approve is refused, nothing saved',
      () async {
        final s1 = await settlementReady();
        // The manager asks for 1000 of profit. Before S1 is approved, the
        // withdrawal shows no settled profit yet.
        final request = await write(
          manager,
          managerChain,
          id: 'w1',
          type: 'withdraw_request',
          body: const {'amount': 1000, 'kind': 'profit'},
        );
        await receive(request);
        await syncedAs(investorSeq: 2, managerSeq: 2);
        final shown = previewWithdrawal(request);
        expect(shown!.settledShare, 0);

        // Approving S1 makes it effective, so the withdrawal's settled share
        // changes. In v1 only this key can approve S1, so the change comes
        // from this writer, saved between the preview and the withdrawal answer.
        final approvedS1 = await writer().answer(
          testId('s1'),
          approve: true,
          shownSettlement: previewSettlement(s1),
        );
        expect(approvedS1.record, isNotNull);
        final savedBefore = (await store.savedTexts(partnership)).length;

        final result = await writer().answer(
          testId('w1'),
          approve: true,
          shownWithdrawal: shown,
        );

        expect(result.refusal, WriteRefusal.summaryChanged);
        expect(result.latestWithdrawal, isNotNull);
        expect(result.latestWithdrawal!.settledShare, greaterThan(0));
        expect(result.latestWithdrawal, isNot(shown));
        expect(await store.savedTexts(partnership), hasLength(savedBefore));
      },
    );

    test('a settlement approve without a shown summary is refused', () async {
      final s1 = await settlementReady();
      expect(previewSettlement(s1), isNotNull);

      final result = await writer().answer(testId('s1'), approve: true);

      expect(result.refusal, WriteRefusal.consentNotShown);
      expect(result.latestSettlement, isNotNull);
      // create, approveCreate, invest, sale and S1: nothing new was saved.
      expect(await store.savedTexts(partnership), hasLength(5));
    });
  });

  group('RecordWriter.propose* creation forms (spec section 5)', () {
    test('proposeInvest writes an invest record for the investor', () async {
      await startWithCreate();
      await syncedAs(investorSeq: 1, managerSeq: 1);

      final result = await writer().proposeInvest(amount: 100000);

      expect(result.record, isNotNull);
      expect(result.record!.type, 'invest');
      expect(result.record!.body['amount'], 100000);
    });

    test('proposeInvest refuses the manager: investor only', () async {
      await startWithCreate();
      await syncedAs(investorSeq: 1, managerSeq: 1);

      final result = await managerWriter().proposeInvest(amount: 100000);

      expect(result.refusal, WriteRefusal.wrongRole);
      // create and approveCreate: nothing new was saved.
      expect(await store.savedTexts(partnership), hasLength(2));
    });

    test('proposeSale writes a sale record for the manager', () async {
      await startWithCreate();
      await syncedAs(investorSeq: 1, managerSeq: 1);

      final result = await managerWriter().proposeSale(amount: 50000);

      expect(result.record, isNotNull);
      expect(result.record!.type, 'sale');
      expect(result.record!.body['amount'], 50000);
    });

    test('proposeSale refuses the investor: manager only', () async {
      await startWithCreate();
      await syncedAs(investorSeq: 1, managerSeq: 1);

      final result = await writer().proposeSale(amount: 50000);

      expect(result.refusal, WriteRefusal.wrongRole);
    });

    test(
      'proposeExpense writes an expense against a budget granted to this key',
      () async {
        await startWithCreate();
        await syncedAs(investorSeq: 1, managerSeq: 1);
        final budget = await writer().proposeBudget(
          amount: 100000,
          grantee: manager.publicKeyBase64Url,
        );
        await syncedAs(investorSeq: 2, managerSeq: 1);
        final approveBudget = await managerWriter().answer(
          budget.record!.id,
          approve: true,
          shownBudget: previewBudget(budget.record!),
        );
        expect(approveBudget.record, isNotNull);
        await syncedAs(investorSeq: 2, managerSeq: 2);

        final result = await managerWriter().proposeExpense(
          amount: 20000,
          budgetId: budget.record!.id,
        );

        expect(result.record, isNotNull);
        expect(result.record!.type, 'expense');
        expect(result.record!.refersTo, budget.record!.id);
      },
    );

    test('proposeExpense refuses the investor: manager only', () async {
      await startWithCreate();
      await syncedAs(investorSeq: 1, managerSeq: 1);

      final result = await writer().proposeExpense(
        amount: 1,
        budgetId: testId('no-such-budget'),
      );

      expect(result.refusal, WriteRefusal.wrongRole);
    });

    test(
      'proposeExpense refuses a budget this key is not granted, or that does '
      'not exist',
      () async {
        await startWithCreate();
        await syncedAs(investorSeq: 1, managerSeq: 1);

        final result = await managerWriter().proposeExpense(
          amount: 1,
          budgetId: testId('no-such-budget'),
        );

        expect(result.refusal, WriteRefusal.noEffectiveBudget);
      },
    );

    test(
      'proposeWithdrawal of kind capital is investor only',
      () async {
        await startWithCreate();
        await syncedAs(investorSeq: 1, managerSeq: 1);

        final fromInvestor = await writer().proposeWithdrawal(
          amount: 100,
          kind: 'capital',
        );
        expect(fromInvestor.record, isNotNull);
        expect(fromInvestor.record!.type, 'withdraw_request');

        final fromManager = await managerWriter().proposeWithdrawal(
          amount: 100,
          kind: 'capital',
        );
        expect(fromManager.refusal, WriteRefusal.wrongRole);
      },
    );

    test(
      'proposeWithdrawal of kind profit is open to either partner',
      () async {
        await startWithCreate();
        await syncedAs(investorSeq: 1, managerSeq: 1);

        final fromInvestor = await writer().proposeWithdrawal(
          amount: 100,
          kind: 'profit',
        );
        expect(fromInvestor.record, isNotNull);
        await syncedAs(investorSeq: 2, managerSeq: 1);

        final fromManager = await managerWriter().proposeWithdrawal(
          amount: 100,
          kind: 'profit',
        );
        expect(fromManager.record, isNotNull);
      },
    );

    test('proposeBudget is open to either partner', () async {
      await startWithCreate();
      await syncedAs(investorSeq: 1, managerSeq: 1);

      final result = await managerWriter().proposeBudget(
        amount: 1000,
        grantee: investor.publicKeyBase64Url,
      );

      expect(result.record, isNotNull);
      expect(result.record!.type, 'budget_proposal');
      expect(result.record!.body['grantee'], investor.publicKeyBase64Url);
    });

    test('proposeRatio is open to either partner', () async {
      await startWithCreate();
      await syncedAs(investorSeq: 1, managerSeq: 1);

      final result = await managerWriter().proposeRatio(
        investorPercent: 50,
        managerPercent: 50,
        effectiveFrom: '2026-11-01',
      );

      expect(result.record, isNotNull);
      expect(result.record!.type, 'ratio_proposal');
      expect(result.record!.body['ratio'], {'investor': 50, 'manager': 50});
    });

    test('proposeReversal reverses a record held on this phone', () async {
      await startWithCreate();
      await syncedAs(investorSeq: 1, managerSeq: 1);
      final invest = await writer().proposeInvest(amount: 100000);
      await syncedAs(investorSeq: 2, managerSeq: 1);

      final result = await writer().proposeReversal(
        targetId: invest.record!.id,
      );

      expect(result.record, isNotNull);
      expect(result.record!.type, 'reversal');
      expect(result.record!.refersTo, invest.record!.id);
    });

    test(
      'proposeReversal refuses a target not held, or not a reversible type',
      () async {
        await startWithCreate();
        await syncedAs(investorSeq: 1, managerSeq: 1);

        final notHeld = await writer().proposeReversal(
          targetId: testId('no-such-record'),
        );
        expect(notHeld.refusal, WriteRefusal.notReversible);

        // partnership_create is held, but it is not one of the reversible
        // types (spec section 5: invest, sale, expense, withdraw_request).
        final wrongType = await writer().proposeReversal(
          targetId: testId('partnership'),
        );
        expect(wrongType.refusal, WriteRefusal.notReversible);
      },
    );

    test(
      'proposeSettlement writes a settlement covering real new business',
      () async {
        await startWithCreate();
        await syncedAs(investorSeq: 1, managerSeq: 1);
        await writer().proposeInvest(amount: 100000);
        await syncedAs(investorSeq: 2, managerSeq: 1);
        await managerWriter().proposeSale(amount: 50000);
        await syncedAs(investorSeq: 2, managerSeq: 2);

        final result = await managerWriter().proposeSettlement();

        expect(result.record, isNotNull);
        expect(result.record!.type, 'settlement');
      },
    );

    test('proposeSettlement refuses the investor: manager only', () async {
      await startWithCreate();
      await syncedAs(investorSeq: 1, managerSeq: 1);
      await writer().proposeInvest(amount: 100000);
      await syncedAs(investorSeq: 2, managerSeq: 1);
      await managerWriter().proposeSale(amount: 50000);
      await syncedAs(investorSeq: 2, managerSeq: 2);

      final result = await writer().proposeSettlement();

      expect(result.refusal, WriteRefusal.wrongRole);
    });

    test(
      'proposeSettlement refuses a cut that covers nothing but the last '
      'settlement and its approve, even though the raw cut grew (spec 6.7, '
      'cut rule 5; decision 2026-10-10), and accepts the next real business',
      () async {
        await startWithCreate();
        await syncedAs(investorSeq: 1, managerSeq: 1);
        await writer().proposeInvest(amount: 100000);
        await syncedAs(investorSeq: 2, managerSeq: 1);
        await managerWriter().proposeSale(amount: 50000);
        await syncedAs(investorSeq: 2, managerSeq: 2);
        final s1 = await managerWriter().proposeSettlement();
        expect(s1.record, isNotNull);
        await syncedAs(investorSeq: 2, managerSeq: 3);
        final approveS1 = await writer().answer(
          s1.record!.id,
          approve: true,
          shownSettlement: previewSettlement(s1.record!),
        );
        expect(approveS1.record, isNotNull);
        await syncedAs(investorSeq: 3, managerSeq: 3);

        final savedBefore = (await store.savedTexts(partnership)).length;
        final s2 = await managerWriter().proposeSettlement();

        expect(s2.refusal, WriteRefusal.emptyCut);
        expect(await store.savedTexts(partnership), hasLength(savedBefore));

        // A new sale after S1 is real business: now S2 is accepted.
        await managerWriter().proposeSale(amount: 10000);
        await syncedAs(investorSeq: 3, managerSeq: 4);

        final s2Again = await managerWriter().proposeSettlement();
        expect(s2Again.record, isNotNull);
        expect(s2Again.record!.type, 'settlement');
      },
    );

    test(
      'a propose while the partnership is still pending is refused',
      () async {
        await startWithUnapprovedCreate();
        await syncedAs(investorSeq: 1, managerSeq: 0);

        final result = await writer().proposeInvest(amount: 100000);

        expect(result.refusal, WriteRefusal.partnershipNotActive);
      },
    );
  });
}
