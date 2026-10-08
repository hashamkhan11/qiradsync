import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/inbox/withdrawal_confirm_screen.dart';
import 'package:mobile/storage/record_store.dart';
import 'package:mobile/storage/record_writer.dart';
import 'package:path/path.dart' as p;
import 'package:qirad_core/qirad_core.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/pump_until.dart';
import 'support/test_ids.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  late Directory dir;
  late RecordStore store;
  late Ed25519KeyPair investor;
  late Ed25519KeyPair manager;
  late String partnership;
  late List<Record> investorChain;
  late List<Record> managerChain;
  late Record s1;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('qirad_withdrawal_screen_test');
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
      time: '2026-10-08T10:00:00Z',
      refersTo: refersTo,
    );
    final signed = await signRecord(unsigned, keys);
    chain.add(signed);
    return signed;
  }

  Future<void> receive(Record record) async {
    expect(
      await store.receive(canonicalJson(record.toJson())),
      ReceiveOutcome.accepted,
    );
  }

  Future<void> syncedAs({required int investorSeq, required int managerSeq}) =>
      store.saveRelayVector(partnership, {
        investor.publicKeyBase64Url: investorSeq,
        manager.publicKeyBase64Url: managerSeq,
      });

  Future<void> startWithCreate() async {
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
    expect(
      await store.startPartnership(
        id: partnership,
        investorKey: investor.publicKeyBase64Url,
        managerKey: manager.publicKeyBase64Url,
        createText: canonicalJson(create.toJson()),
      ),
      ReceiveOutcome.accepted,
    );
  }

  /// Invest 1,000, sale 500, a pending settlement S1, and a manager request
  /// to withdraw 10 of profit. Before S1 is approved, the manager's settled
  /// share is 0 (mirrors record_writer_test.dart's own summary-changed case).
  Future<Record> withdrawalReady() async {
    await startWithCreate();
    await receive(
      await write(
        investor,
        investorChain,
        id: 'invest-1',
        type: 'invest',
        body: const {'amount': 100000},
      ),
    );
    await receive(
      await write(
        manager,
        managerChain,
        id: 'sale-1',
        type: 'sale',
        body: const {'amount': 50000},
      ),
    );
    s1 = await write(
      manager,
      managerChain,
      id: 's1',
      type: 'settlement',
      body: {
        'cut': {investor.publicKeyBase64Url: 2, manager.publicKeyBase64Url: 1},
      },
    );
    await receive(s1);
    final request = await write(
      manager,
      managerChain,
      id: 'w1',
      type: 'withdraw_request',
      body: const {'amount': 1000, 'kind': 'profit'},
    );
    await receive(request);
    await syncedAs(investorSeq: 2, managerSeq: 2);
    return request;
  }

  RecordWriter investorWriter() =>
      RecordWriter(keys: investor, partnership: partnership, store: store);

  /// The summary the investor would be shown for settlement [proposal] now,
  /// the same way the real screen computes it (spec 6.7).
  SettlementConsent? previewSettlement(Record proposal) {
    final validator = store.validatorFor(partnership);
    final keys = validator.partnershipKeys!;
    final preview = buildRecord(
      ledger: validator.usableRecords,
      author: investor.publicKeyBase64Url,
      partnership: partnership,
      id: testId('preview-${proposal.id}'),
      type: 'approve',
      body: const {},
      time: '2026-10-08T10:00:00Z',
      refersTo: proposal.id,
    );
    return settlementConsent(
      validator.usableRecords,
      partnershipKeys: keys,
      proposal: proposal,
      answer: preview,
    );
  }

  Future<void> pump(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    await tester.pumpWidget(
      MaterialApp(
        home: WithdrawalConfirmScreen(
          store: store,
          writer: investorWriter(),
          myKey: investor.publicKeyBase64Url,
          partnership: partnership,
          targetId: testId('w1'),
          onSyncNow: () async {},
        ),
      ),
    );
  }

  /// The value `Text` next to the summary row labelled [label] (the row puts
  /// the label and the value side by side in one `Row`, as `InboxSummaryRow`
  /// builds it).
  Text valueFor(WidgetTester tester, String label) {
    final row = find.ancestor(of: find.text(label), matching: find.byType(Row));
    return tester.widget<Text>(
      find.descendant(of: row, matching: find.byType(Text)).last,
    );
  }

  // The whole test body runs inside one `runAsync` call, with a plain
  // `tester.pump()` after each real write (see the matching note in
  // settlement_confirm_screen_test.dart for why: mixing fake-async
  // `testWidgets` time with sqflite's real I/O, across more than one
  // `runAsync`/`pumpAndSettle` call, was an occasional real hang).
  group('WithdrawalConfirmScreen (spec 6.7)', () {
    testWidgets(
      'a summary changed by an approve elsewhere shows the new numbers, '
      'highlighted',
      (tester) async {
        await tester.runAsync(() async {
          await withdrawalReady();
          await pump(tester);
          await tester.pump();

          // Before S1 is approved, the manager has no settled share yet.
          expect(valueFor(tester, 'Settled share so far').data, 'Rs 0.00');

          // S1 is approved by a different write, while this screen is
          // already showing its (now stale) numbers.
          final s1Approved = await investorWriter().answer(
            testId('s1'),
            approve: true,
            shownSettlement: previewSettlement(s1),
          );
          expect(s1Approved.record, isNotNull);

          await tester.tap(find.widgetWithText(ElevatedButton, 'Approve'));
          // The approve is refused after a real summary recompute; wait for
          // the refusal message to land instead of guessing a pump count.
          await pumpUntil(
            tester,
            () => find
                .text('The numbers changed. Check them again before approving.')
                .evaluate()
                .isNotEmpty,
          );

          expect(
            find.text(
              'The numbers changed. Check them again before approving.',
            ),
            findsOneWidget,
          );
          final settledShare = valueFor(tester, 'Settled share so far');
          expect(settledShare.data, 'Rs 200.00');
          expect(
            settledShare.style?.color,
            Theme.of(
              tester.element(find.byType(MaterialApp)),
            ).colorScheme.error,
          );
        });
      },
    );
  });
}
