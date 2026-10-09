import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/inbox/budget_confirm_screen.dart';
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
    dir = await Directory.systemTemp.createTemp('qirad_budget_screen_test');
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

  /// The investor proposes a budget naming themselves as grantee, and the
  /// manager answers it, so the grantee shown is not the viewer and must
  /// appear as a raw key, not "You". Cash balance comes from an earlier
  /// sale; there is no other open budget yet, so there is nothing to warn
  /// about (spec 6.4).
  Future<Record> budgetReady() async {
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
    final proposal = await write(
      investor,
      investorChain,
      id: 'budget-1',
      type: 'budget_proposal',
      body: {'grantee': investor.publicKeyBase64Url, 'amount': 20000},
    );
    await receive(proposal);
    await syncedAs(investorSeq: 2, managerSeq: 1);
    return proposal;
  }

  /// The manager proposes a budget naming the investor as grantee, so the
  /// investor is the one answering a proposal about their own spending.
  Future<Record> selfGranteeBudgetReady() async {
    await startWithCreate();
    await receive(
      await write(
        manager,
        managerChain,
        id: 'sale-2',
        type: 'sale',
        body: const {'amount': 50000},
      ),
    );
    final proposal = await write(
      manager,
      managerChain,
      id: 'budget-2',
      type: 'budget_proposal',
      body: {'grantee': investor.publicKeyBase64Url, 'amount': 10000},
    );
    await receive(proposal);
    await syncedAs(investorSeq: 1, managerSeq: 2);
    return proposal;
  }

  /// A first budget (40000) is already approved against a 50000 cash
  /// balance. A second proposal for 20000 would push open budgets to 60000,
  /// past what is available — the warning case (spec 6.4's "should warn, not
  /// block").
  Future<Record> overCommittedBudgetReady() async {
    await startWithCreate();
    await receive(
      await write(
        manager,
        managerChain,
        id: 'sale-3',
        type: 'sale',
        body: const {'amount': 50000},
      ),
    );
    final first = await write(
      manager,
      managerChain,
      id: 'budget-3',
      type: 'budget_proposal',
      body: {'grantee': manager.publicKeyBase64Url, 'amount': 40000},
    );
    await receive(first);
    await receive(
      await write(
        investor,
        investorChain,
        id: 'budget-3-approve',
        type: 'approve',
        refersTo: first.id,
      ),
    );
    final second = await write(
      investor,
      investorChain,
      id: 'budget-4',
      type: 'budget_proposal',
      body: {'grantee': manager.publicKeyBase64Url, 'amount': 20000},
    );
    await receive(second);
    await syncedAs(investorSeq: 3, managerSeq: 2);
    return second;
  }

  RecordWriter investorWriter({Future<void> Function()? beforeSign}) =>
      RecordWriter(
        keys: investor,
        partnership: partnership,
        store: store,
        beforeSign: beforeSign,
      );

  RecordWriter managerWriter({Future<void> Function()? beforeSign}) =>
      RecordWriter(
        keys: manager,
        partnership: partnership,
        store: store,
        beforeSign: beforeSign,
      );

  /// The investor proposes a budget, and the manager answers it from a
  /// different write before this screen is ever opened.
  Future<Record> answeredElsewhereReady() async {
    final proposal = await budgetReady();
    final validator = store.validatorFor(partnership);
    final shown = budgetConsent(
      validator.usableRecords,
      partnershipKeys: validator.partnershipKeys!,
      proposal: proposal,
    );
    final answered = await managerWriter().answer(
      proposal.id,
      approve: true,
      shownBudget: shown,
    );
    expect(answered.record, isNotNull);
    return proposal;
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
        home: BudgetConfirmScreen(
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

  group('BudgetConfirmScreen (spec section 5, 6.4)', () {
    testWidgets(
      'shows amount, cash balance and open budgets, with no warning when '
      'there is room',
      (tester) async {
        await tester.runAsync(() async {
          final proposal = await budgetReady();
          await pump(
            tester,
            myKey: manager.publicKeyBase64Url,
            targetId: proposal.id,
          );
          await tester.pump();

          expect(valueFor(tester, 'Grantee').data, investor.publicKeyBase64Url);
          expect(valueFor(tester, 'Amount').data, 'Rs 200.00');
          expect(valueFor(tester, 'Cash balance now').data, 'Rs 1,000.00');
          expect(valueFor(tester, 'Other open budgets').data, 'Rs 0.00');
          expect(find.textContaining('exceed the cash'), findsNothing);

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
              (r) => r.type == 'approve' && r.refersTo == proposal.id,
            ),
            hasLength(1),
          );
        });
      },
    );

    testWidgets(
      "labels the grantee 'You' when the viewer is the one being granted "
      'the budget',
      (tester) async {
        await tester.runAsync(() async {
          final proposal = await selfGranteeBudgetReady();
          await pump(
            tester,
            myKey: investor.publicKeyBase64Url,
            targetId: proposal.id,
          );
          await tester.pump();

          expect(valueFor(tester, 'Grantee').data, 'You');
        });
      },
    );

    testWidgets(
      'warns when approving would let open budgets exceed available cash',
      (tester) async {
        await tester.runAsync(() async {
          final proposal = await overCommittedBudgetReady();
          await pump(
            tester,
            myKey: manager.publicKeyBase64Url,
            targetId: proposal.id,
          );
          await tester.pump();

          expect(valueFor(tester, 'Other open budgets').data, 'Rs 400.00');
          expect(valueFor(tester, 'Cash balance now').data, 'Rs 500.00');
          expect(find.textContaining('exceed the cash'), findsOneWidget);
          // The warning is a warning, not a block (spec 6.4).
          expect(find.widgetWithText(ElevatedButton, 'Approve'), findsOneWidget);
        });
      },
    );

    testWidgets(
      'already answered by a write made elsewhere',
      (tester) async {
        await tester.runAsync(() async {
          final proposal = await answeredElsewhereReady();
          await pump(
            tester,
            myKey: manager.publicKeyBase64Url,
            targetId: proposal.id,
          );
          await tester.pump();

          expect(find.text('This was already answered.'), findsOneWidget);
          expect(find.widgetWithText(ElevatedButton, 'Approve'), findsNothing);
          expect(find.widgetWithText(OutlinedButton, 'Reject'), findsNothing);
        });
      },
    );

    testWidgets('rejecting asks "are you sure?" first', (tester) async {
      await tester.runAsync(() async {
        final proposal = await budgetReady();
        await pump(
          tester,
          myKey: manager.publicKeyBase64Url,
          targetId: proposal.id,
        );
        await tester.pump();

        await tester.tap(find.widgetWithText(OutlinedButton, 'Reject'));
        await tester.pump();
        expect(find.text('Reject this budget proposal?'), findsOneWidget);

        await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
        await tester.pump();
        expect(find.text('Reject this budget proposal?'), findsNothing);

        await tester.tap(find.widgetWithText(OutlinedButton, 'Reject'));
        await tester.pump();
        await tester.tap(find.widgetWithText(FilledButton, 'Reject'));
        await pumpUntil(
          tester,
          () => find.widgetWithText(OutlinedButton, 'Reject').evaluate().isEmpty,
        );

        final saved = [
          for (final text in await store.savedTexts(partnership))
            Record.fromJson(jsonDecode(text) as Map<String, dynamic>),
        ];
        expect(
          saved.where((r) => r.type == 'reject' && r.refersTo == proposal.id),
          hasLength(1),
        );
      });
    });

    testWidgets(
      'disables both buttons for the whole time a write is in flight',
      (tester) async {
        await tester.runAsync(() async {
          final proposal = await budgetReady();
          final gate = Completer<void>();
          await pump(
            tester,
            myKey: manager.publicKeyBase64Url,
            targetId: proposal.id,
            writerOverride: managerWriter(beforeSign: () => gate.future),
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
