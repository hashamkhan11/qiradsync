import 'dart:async';
import 'dart:convert';
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

  /// A withdraw_request with no amount and no kind. `approvalsInbox` does no
  /// shape checking for a withdrawal (unlike a settlement), so this still
  /// shows up as `canApprove: true, blockedReason: null` — but it can never
  /// become effective, so `withdrawalConsent` is genuinely null here. Unlike
  /// the settlement screen's missing-summary state, this one really is
  /// reachable through the inbox in real use, not just by hand-building a
  /// record outside it.
  Future<void> malformedWithdrawalReady() async {
    await startWithCreate();
    await receive(
      await write(
        manager,
        managerChain,
        id: 'w1',
        type: 'withdraw_request',
        body: const {},
      ),
    );
    await syncedAs(investorSeq: 1, managerSeq: 1);
  }

  RecordWriter investorWriter({Future<void> Function()? beforeSign}) =>
      RecordWriter(
        keys: investor,
        partnership: partnership,
        store: store,
        beforeSign: beforeSign,
      );

  /// Every own record this phone has saved, newest-ignorant: just the `seq`
  /// values, so a test can check none repeat (a repeat would mean a fork).
  Future<List<int>> mySeqs() async {
    final saved = await store.savedTexts(partnership);
    return [
          for (final text in saved)
            Record.fromJson(jsonDecode(text) as Map<String, dynamic>),
        ]
        .where((r) => r.author == investor.publicKeyBase64Url)
        .map((r) => r.seq)
        .toList();
  }

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

  Future<void> pump(
    WidgetTester tester, {
    Future<void> Function()? onSyncNow,
    RecordWriter? writerOverride,
    String? targetId,
  }) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    await tester.pumpWidget(
      MaterialApp(
        home: WithdrawalConfirmScreen(
          store: store,
          writer: writerOverride ?? investorWriter(),
          myKey: investor.publicKeyBase64Url,
          partnership: partnership,
          targetId: targetId ?? testId('w1'),
          onSyncNow: onSyncNow ?? () async {},
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

    testWidgets('no Approve when the request can never become effective', (
      tester,
    ) async {
      await tester.runAsync(() async {
        await malformedWithdrawalReady();
        await pump(tester);
        await tester.pump();

        expect(find.widgetWithText(ElevatedButton, 'Approve'), findsNothing);
        expect(find.text('No numbers to show yet.'), findsOneWidget);
        expect(find.widgetWithText(OutlinedButton, 'Reject'), findsOneWidget);
      });
    });

    testWidgets(
      'disables both buttons for the whole time a write is in flight',
      (tester) async {
        await tester.runAsync(() async {
          await withdrawalReady();
          // A write that will not finish until the test says so, so the
          // disabled check cannot depend on how fast the real database
          // happens to be (no pump-count or real-delay guesswork).
          final gate = Completer<void>();
          await pump(
            tester,
            writerOverride: investorWriter(beforeSign: () => gate.future),
          );
          await tester.pump();

          await tester.tap(find.widgetWithText(ElevatedButton, 'Approve'));
          // `_writing = true` is set by a synchronous `setState` before the
          // writer is even called, so one pump is enough to see it, no
          // matter how long the held write takes.
          await tester.pump();

          expect(
            tester
                .widget<ElevatedButton>(
                  find.widgetWithText(ElevatedButton, 'Approve'),
                )
                .onPressed,
            isNull,
          );
          expect(
            tester
                .widget<OutlinedButton>(
                  find.widgetWithText(OutlinedButton, 'Reject'),
                )
                .onPressed,
            isNull,
          );

          gate.complete();
          await pumpUntil(
            tester,
            () => find
                .widgetWithText(ElevatedButton, 'Approve')
                .evaluate()
                .isEmpty,
          );
          expect(await mySeqs(), [1, 2, 3]);
        });
      },
    );

    testWidgets('rejecting asks "are you sure?" first', (tester) async {
      await tester.runAsync(() async {
        await withdrawalReady();
        await pump(tester);
        await tester.pump();

        await tester.tap(find.widgetWithText(OutlinedButton, 'Reject'));
        await tester.pump();
        expect(find.text('Reject this withdrawal?'), findsOneWidget);
        expect(find.text('This cannot be undone.'), findsOneWidget);

        // Cancel: the dialog closes, nothing is written.
        await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
        await tester.pump();
        expect(find.text('Reject this withdrawal?'), findsNothing);
        expect(await store.savedTexts(partnership), hasLength(5));

        // Reject again, this time confirming in the dialog.
        await tester.tap(find.widgetWithText(OutlinedButton, 'Reject'));
        await tester.pump();
        await tester.tap(find.widgetWithText(FilledButton, 'Reject'));
        await pumpUntil(
          tester,
          () =>
              find.widgetWithText(OutlinedButton, 'Reject').evaluate().isEmpty,
        );
        // The confirmed reject is the investor's own third record (after
        // create and invest).
        expect(await mySeqs(), [1, 2, 3]);
      });
    });

    testWidgets('a quick double tap on Approve saves exactly one record', (
      tester,
    ) async {
      await tester.runAsync(() async {
        await withdrawalReady();
        await pump(tester);
        await tester.pump();

        final approve = find.widgetWithText(ElevatedButton, 'Approve');
        // No pump between the two taps: both land on the same build, where
        // the button is still enabled, the same way two real, fast taps
        // could both reach the handler before the first rebuild disables it.
        await tester.tap(approve);
        await tester.tap(approve);
        await pumpUntil(tester, () => approve.evaluate().isEmpty);

        // Exactly one approve was saved (create, invest, sale, settlement,
        // request, approve), and no two of my own records share a seq: the
        // second tap's write is refused as alreadyAnswered by the serial
        // queue, not raced into a fork.
        expect(await store.savedTexts(partnership), hasLength(6));
        final seqs = await mySeqs();
        expect(seqs, hasLength(seqs.toSet().length));
        // The second tap is refused as alreadyAnswered, but that refusal
        // never has anywhere to show: once the request is decided, `build`
        // always takes the early "This was already answered." branch,
        // which does not render `_message` at all.
        expect(find.text('Already answered.'), findsNothing);
      });
    });
  });
}
