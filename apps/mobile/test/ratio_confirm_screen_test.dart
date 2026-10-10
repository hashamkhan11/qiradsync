import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/inbox/ratio_confirm_screen.dart';
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
    dir = await Directory.systemTemp.createTemp('qirad_ratio_screen_test');
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

  /// The manager proposes a ratio change. The create needs the manager's own
  /// approve first — `partnership_create` needs approval like any other
  /// proposal (spec section 5) — so the create's ratio (60/40) can become the
  /// active one. No change is effective yet, so 60/40 stays active (spec 6.6).
  Future<Record> ratioReady() async {
    await startWithCreate();
    final create = investorChain.single;
    final createApprove = await write(
      manager,
      managerChain,
      id: 'create-approve',
      type: 'approve',
      refersTo: create.id,
    );
    await receive(createApprove);
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
    await syncedAs(investorSeq: 1, managerSeq: 2);
    return proposal;
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

  /// The manager proposes a ratio change, and the investor answers it from a
  /// different write before this screen is ever opened.
  Future<Record> answeredElsewhereReady() async {
    final proposal = await ratioReady();
    final validator = store.validatorFor(partnership);
    final shown = ratioConsent(
      validator.usableRecords,
      partnershipKeys: validator.partnershipKeys!,
      proposal: proposal,
    );
    final answered = await investorWriter().answer(
      proposal.id,
      approve: true,
      shownRatio: shown,
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
        home: RatioConfirmScreen(
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

  group('RatioConfirmScreen (spec section 5, 6.6)', () {
    testWidgets(
      'shows the current ratio next to the proposed one, and the start date',
      (tester) async {
        await tester.runAsync(() async {
          final proposal = await ratioReady();
          await pump(
            tester,
            myKey: investor.publicKeyBase64Url,
            targetId: proposal.id,
          );
          await tester.pump();

          expect(valueFor(tester, 'Current ratio').data, '60/40');
          expect(valueFor(tester, 'Proposed ratio').data, '50/50');
          expect(valueFor(tester, 'Starts').data, '2026-11-01');
          expect(
            find.textContaining('applies after the next settlement'),
            findsOneWidget,
          );

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

    testWidgets('already answered by a write made elsewhere', (tester) async {
      await tester.runAsync(() async {
        final proposal = await answeredElsewhereReady();
        await pump(
          tester,
          myKey: investor.publicKeyBase64Url,
          targetId: proposal.id,
        );
        await tester.pump();

        expect(find.text('This was already answered.'), findsOneWidget);
        expect(find.widgetWithText(ElevatedButton, 'Approve'), findsNothing);
        expect(find.widgetWithText(OutlinedButton, 'Reject'), findsNothing);
      });
    });

    testWidgets('rejecting asks "are you sure?" first', (tester) async {
      await tester.runAsync(() async {
        final proposal = await ratioReady();
        await pump(
          tester,
          myKey: investor.publicKeyBase64Url,
          targetId: proposal.id,
        );
        await tester.pump();

        await tester.tap(find.widgetWithText(OutlinedButton, 'Reject'));
        await tester.pump();
        expect(find.text('Reject this ratio change?'), findsOneWidget);

        await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
        await tester.pump();
        expect(find.text('Reject this ratio change?'), findsNothing);

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
          saved.where((r) => r.type == 'reject' && r.refersTo == proposal.id),
          hasLength(1),
        );
      });
    });

    testWidgets(
      'disables both buttons for the whole time a write is in flight',
      (tester) async {
        await tester.runAsync(() async {
          final proposal = await ratioReady();
          final gate = Completer<void>();
          await pump(
            tester,
            myKey: investor.publicKeyBase64Url,
            targetId: proposal.id,
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
