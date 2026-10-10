import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/inbox/consent_preview.dart';
import 'package:mobile/inbox/reversal_confirm_screen.dart';
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

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('qirad_reversal_screen_test');
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
      time: '2026-10-09T10:00:00Z',
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

  /// The investor's partnership_create, saved with the pins (spec 2.1), with
  /// no approve yet, so the partnership is still pending (spec section 5).
  Future<void> startWithUnapprovedCreate() async {
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

  /// [startWithUnapprovedCreate], then the manager's approve of it, so the
  /// partnership is active (spec section 5) and reversals can be answered.
  Future<void> startWithCreate() async {
    await startWithUnapprovedCreate();
    await receive(
      await write(
        manager,
        managerChain,
        id: 'approve-create',
        type: 'approve',
        refersTo: testId('partnership'),
      ),
    );
  }

  /// The manager reverses the investor's invest. Only capital and cash move;
  /// there is no period behind an invest (spec 6.5).
  Future<Record> investReversalReady() async {
    await startWithCreate();
    final invest = await write(
      investor,
      investorChain,
      id: 'invest-1',
      type: 'invest',
      body: const {'amount': 100000},
    );
    await receive(invest);
    final reversal = await write(
      manager,
      managerChain,
      id: 'reversal-invest',
      type: 'reversal',
      refersTo: invest.id,
    );
    await receive(reversal);
    await syncedAs(investorSeq: 2, managerSeq: 2);
    return reversal;
  }

  /// The investor reverses the manager's approved expense while its home
  /// period (1) is still open: the result moves directly, and the expense's
  /// budget is freed (spec 6.4, 6.5).
  Future<Record> expenseReversalReady() async {
    await startWithCreate();
    await receive(
      await write(
        manager,
        managerChain,
        id: 'sale-1',
        type: 'sale',
        body: const {'amount': 100000},
      ),
    );
    final budget = await write(
      investor,
      investorChain,
      id: 'budget-1',
      type: 'budget_proposal',
      body: {'grantee': manager.publicKeyBase64Url, 'amount': 30000},
    );
    await receive(budget);
    await receive(
      await write(
        manager,
        managerChain,
        id: 'budget-approve',
        type: 'approve',
        refersTo: budget.id,
      ),
    );
    final expense = await write(
      manager,
      managerChain,
      id: 'expense-1',
      type: 'expense',
      body: const {'amount': 12000},
      refersTo: budget.id,
    );
    await receive(expense);
    final reversal = await write(
      investor,
      investorChain,
      id: 'reversal-expense',
      type: 'reversal',
      refersTo: expense.id,
    );
    await receive(reversal);
    await syncedAs(investorSeq: 3, managerSeq: 4);
    return reversal;
  }

  /// The investor reverses the manager's sale after its home period (1) was
  /// settled and closed: the result cannot move any more, so this books a
  /// prior-period correction instead (spec 6.7 "Prior-period adjustments").
  Future<Record> closedSaleReversalReady() async {
    await startWithCreate();
    final sale = await write(
      manager,
      managerChain,
      id: 'sale-2',
      type: 'sale',
      body: const {'amount': 50000},
    );
    await receive(sale);
    final settlement = await write(
      manager,
      managerChain,
      id: 'settlement-1',
      type: 'settlement',
      body: {
        'cut': {
          investor.publicKeyBase64Url: investorChain.length,
          manager.publicKeyBase64Url: managerChain.length,
        },
      },
    );
    await receive(settlement);
    await receive(
      await write(
        investor,
        investorChain,
        id: 'settlement-approve',
        type: 'approve',
        refersTo: settlement.id,
      ),
    );
    final reversal = await write(
      investor,
      investorChain,
      id: 'reversal-sale-closed',
      type: 'reversal',
      refersTo: sale.id,
    );
    await receive(reversal);
    await syncedAs(investorSeq: 3, managerSeq: 3);
    return reversal;
  }

  /// Reversing a `ratio_proposal` is invalid in v1 (spec section 5): the
  /// approve can never cancel anything, so there is nothing to show, and
  /// Approve must stay hidden — but this did go through `receive()` with no
  /// bypass, since nothing in the schema forbids a reversal naming any id.
  Future<Record> nonReversibleReady() async {
    await startWithCreate();
    final proposal = await write(
      manager,
      managerChain,
      id: 'ratio-1',
      type: 'ratio_proposal',
      body: {
        'ratio': {'investor': 50, 'manager': 50},
        'effectiveFrom': '2026-11-01',
      },
    );
    await receive(proposal);
    await receive(
      await write(
        investor,
        investorChain,
        id: 'ratio-approve',
        type: 'approve',
        refersTo: proposal.id,
      ),
    );
    final reversal = await write(
      investor,
      investorChain,
      id: 'reversal-ratio',
      type: 'reversal',
      refersTo: proposal.id,
    );
    await receive(reversal);
    await syncedAs(investorSeq: 3, managerSeq: 2);
    return reversal;
  }

  RecordWriter investorWriter({Future<void> Function()? beforeSign}) =>
      RecordWriter.forTesting(
        keys: investor,
        partnership: partnership,
        store: store,
        beforeSign: beforeSign,
      );

  RecordWriter managerWriter({Future<void> Function()? beforeSign}) =>
      RecordWriter.forTesting(
        keys: manager,
        partnership: partnership,
        store: store,
        beforeSign: beforeSign,
      );

  /// The manager reverses the investor's invest, and the investor answers it
  /// from a different write before this screen is ever opened.
  Future<Record> answeredElsewhereReady() async {
    final reversal = await investReversalReady();
    final validator = store.validatorFor(partnership);
    final shown = reversalConsent(
      validator.usableRecords,
      partnershipKeys: validator.partnershipKeys!,
      reversal: reversal,
      answer: previewApprove(
        ledger: validator.usableRecords,
        author: investor.publicKeyBase64Url,
        partnership: partnership,
        targetId: reversal.id,
      ),
    );
    final answered = await investorWriter().answer(
      reversal.id,
      approve: true,
      shownReversal: shown,
    );
    expect(answered.record, isNotNull);
    return reversal;
  }

  Future<void> pump(
    WidgetTester tester, {
    required String myKey,
    required String targetId,
    RecordWriter? writerOverride,
  }) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    await tester.pumpWidget(
      MaterialApp(
        home: ReversalConfirmScreen(
          store: store,
          writer:
              writerOverride ??
              (myKey == investor.publicKeyBase64Url
                  ? investorWriter()
                  : managerWriter()),
          myKey: myKey,
          partnership: partnership,
          targetId: targetId,
          onSyncNow: () async {},
        ),
      ),
    );
  }

  Text valueFor(WidgetTester tester, String label) {
    final row = find.ancestor(of: find.text(label), matching: find.byType(Row));
    return tester.widget<Text>(
      find.descendant(of: row, matching: find.byType(Text)).last,
    );
  }

  group('ReversalConfirmScreen (spec section 5, 6.7)', () {
    testWidgets(
      'reversing an invest shows capital and cash only, no period fields',
      (tester) async {
        await tester.runAsync(() async {
          final reversal = await investReversalReady();
          await pump(
            tester,
            myKey: investor.publicKeyBase64Url,
            targetId: reversal.id,
          );
          await tester.pump();

          expect(valueFor(tester, 'Reversing').data, 'invest (Rs 1,000.00)');
          expect(valueFor(tester, 'Capital change').data, '-Rs 1,000.00');
          expect(valueFor(tester, 'Cash change').data, '-Rs 1,000.00');
          expect(find.textContaining('Result change'), findsNothing);
          expect(find.textContaining('prior-period adjustment'), findsNothing);

          await tester.tap(find.widgetWithText(ElevatedButton, 'Approve'));
          await pumpUntil(
            tester,
            () => find
                .widgetWithText(ElevatedButton, 'Approve')
                .evaluate()
                .isEmpty,
          );

          final saved = [
            for (final text in await store.savedTexts(partnership))
              Record.fromJson(jsonDecode(text) as Map<String, dynamic>),
          ];
          expect(
            saved.where(
              (r) => r.type == 'approve' && r.refersTo == reversal.id,
            ),
            hasLength(1),
          );
        });
      },
    );

    testWidgets(
      'reversing an expense in the open period shows cash, result and '
      'the freed budget',
      (tester) async {
        await tester.runAsync(() async {
          final reversal = await expenseReversalReady();
          await pump(
            tester,
            myKey: manager.publicKeyBase64Url,
            targetId: reversal.id,
          );
          await tester.pump();

          expect(valueFor(tester, 'Cash change').data, 'Rs 120.00');
          expect(
            valueFor(tester, 'Result change (period 1)').data,
            'Rs 120.00',
          );
          expect(valueFor(tester, 'Freed budget').data, 'Rs 120.00');
          expect(find.textContaining('prior-period adjustment'), findsNothing);
        });
      },
    );

    testWidgets('reversing a sale after its period closed books a prior-period '
        'correction instead of a result change', (tester) async {
      await tester.runAsync(() async {
        final reversal = await closedSaleReversalReady();
        await pump(
          tester,
          myKey: manager.publicKeyBase64Url,
          targetId: reversal.id,
        );
        await tester.pump();

        expect(find.textContaining('prior-period adjustment'), findsOneWidget);
        expect(
          valueFor(tester, 'Investor share correction').data,
          '-Rs 300.00',
        );
        expect(valueFor(tester, 'Manager share correction').data, '-Rs 200.00');
        expect(find.textContaining('Result change'), findsNothing);
      });
    });

    testWidgets(
      'a reversal of a kind that can never be reversed shows no numbers and '
      'no Approve, but Reject still works',
      (tester) async {
        await tester.runAsync(() async {
          final reversal = await nonReversibleReady();
          await pump(
            tester,
            myKey: manager.publicKeyBase64Url,
            targetId: reversal.id,
          );
          await tester.pump();

          expect(find.text('No numbers to show yet.'), findsOneWidget);
          expect(find.widgetWithText(ElevatedButton, 'Approve'), findsNothing);
          expect(find.widgetWithText(OutlinedButton, 'Reject'), findsOneWidget);
        });
      },
    );

    testWidgets('already answered by a write made elsewhere', (tester) async {
      await tester.runAsync(() async {
        final reversal = await answeredElsewhereReady();
        await pump(
          tester,
          myKey: investor.publicKeyBase64Url,
          targetId: reversal.id,
        );
        await tester.pump();

        expect(find.text('This was already answered.'), findsOneWidget);
        expect(find.widgetWithText(ElevatedButton, 'Approve'), findsNothing);
        expect(find.widgetWithText(OutlinedButton, 'Reject'), findsNothing);
      });
    });

    testWidgets('rejecting asks "are you sure?" first', (tester) async {
      await tester.runAsync(() async {
        final reversal = await investReversalReady();
        await pump(
          tester,
          myKey: investor.publicKeyBase64Url,
          targetId: reversal.id,
        );
        await tester.pump();

        await tester.tap(find.widgetWithText(OutlinedButton, 'Reject'));
        await tester.pump();
        expect(find.text('Reject this reversal?'), findsOneWidget);

        await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
        await tester.pump();
        expect(find.text('Reject this reversal?'), findsNothing);

        await tester.tap(find.widgetWithText(OutlinedButton, 'Reject'));
        await tester.pump();
        await tester.tap(find.widgetWithText(FilledButton, 'Reject'));
        await pumpUntil(
          tester,
          () =>
              find.widgetWithText(OutlinedButton, 'Reject').evaluate().isEmpty,
        );

        final saved = [
          for (final text in await store.savedTexts(partnership))
            Record.fromJson(jsonDecode(text) as Map<String, dynamic>),
        ];
        expect(
          saved.where((r) => r.type == 'reject' && r.refersTo == reversal.id),
          hasLength(1),
        );
      });
    });

    testWidgets(
      'disables both buttons for the whole time a write is in flight',
      (tester) async {
        await tester.runAsync(() async {
          final reversal = await investReversalReady();
          final gate = Completer<void>();
          await pump(
            tester,
            myKey: investor.publicKeyBase64Url,
            targetId: reversal.id,
            writerOverride: investorWriter(beforeSign: () => gate.future),
          );
          await tester.pump();

          await tester.tap(find.widgetWithText(ElevatedButton, 'Approve'));
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
        });
      },
    );
  });
}
