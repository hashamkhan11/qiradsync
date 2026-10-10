import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/inbox/partnership_create_confirm_screen.dart';
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

  setUp(() async {
    dir = await Directory.systemTemp.createTemp(
      'qirad_partnership_create_screen_test',
    );
    store = await RecordStore.open(
      factory: databaseFactoryFfi,
      path: p.join(dir.path, 'records.db'),
    );
    investor = await generateEd25519KeyPair();
    manager = await generateEd25519KeyPair();
    partnership = testId('partnership');
    investorChain = [];
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
  }) async {
    final unsigned = buildRecord(
      ledger: chain,
      author: keys.publicKeyBase64Url,
      partnership: partnership,
      id: testId(id),
      type: type,
      body: body,
      time: '2026-10-09T10:00:00Z',
    );
    final signed = await signRecord(unsigned, keys);
    chain.add(signed);
    return signed;
  }

  Future<void> syncedAs({required int investorSeq, required int managerSeq}) =>
      store.saveRelayVector(partnership, {
        investor.publicKeyBase64Url: investorSeq,
        manager.publicKeyBase64Url: managerSeq,
      });

  /// The investor's create, accepted but not yet approved by the manager —
  /// exactly the state in which the manager's inbox shows it (spec 2.1, 5).
  Future<void> createPending() async {
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
    await syncedAs(investorSeq: 1, managerSeq: 0);
  }

  RecordWriter managerWriter({Future<void> Function()? beforeSign}) =>
      RecordWriter.forTesting(
        keys: manager,
        partnership: partnership,
        store: store,
        beforeSign: beforeSign,
      );

  Future<void> pump(WidgetTester tester, {RecordWriter? writerOverride}) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    await tester.pumpWidget(
      MaterialApp(
        home: PartnershipCreateConfirmScreen(
          store: store,
          writer: writerOverride ?? managerWriter(),
          myKey: manager.publicKeyBase64Url,
          partnership: partnership,
          targetId: testId('partnership'),
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

  group('PartnershipCreateConfirmScreen (spec 2.1, 5)', () {
    testWidgets(
      'shows both keys, the investor share and a safety code; Approve '
      'starts disabled with the checkbox unticked',
      (tester) async {
        await tester.runAsync(() async {
          await createPending();
          await pump(tester);
          await tester.pump();

          expect(
            valueFor(tester, 'Investor').data,
            investor.publicKeyBase64Url,
          );
          expect(valueFor(tester, 'Manager').data, manager.publicKeyBase64Url);
          expect(valueFor(tester, 'Investor share').data, '60% (manager 40%)');
          expect(find.byKey(const Key('safety-code')), findsOneWidget);
          final expectedCode = safetyCode(
            investorKey: investor.publicKeyBase64Url,
            managerKey: manager.publicKeyBase64Url,
          );
          expect(find.text(expectedCode), findsOneWidget);

          final checkbox = tester.widget<CheckboxListTile>(
            find.byKey(const Key('code-matches-checkbox')),
          );
          expect(checkbox.value, isFalse);
          expect(
            tester
                .widget<ElevatedButton>(
                  find.widgetWithText(ElevatedButton, 'Approve'),
                )
                .onPressed,
            isNull,
          );
        });
      },
    );

    testWidgets(
      'ticking the checkbox enables Approve; approving writes the approve '
      'record',
      (tester) async {
        await tester.runAsync(() async {
          await createPending();
          await pump(tester);
          await tester.pump();

          await tester.tap(find.byKey(const Key('code-matches-checkbox')));
          await tester.pump();
          expect(
            tester
                .widget<ElevatedButton>(
                  find.widgetWithText(ElevatedButton, 'Approve'),
                )
                .onPressed,
            isNotNull,
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
              (r) => r.type == 'approve' && r.refersTo == testId('partnership'),
            ),
            hasLength(1),
          );
        });
      },
    );

    testWidgets('unticking the checkbox again disables Approve', (
      tester,
    ) async {
      await tester.runAsync(() async {
        await createPending();
        await pump(tester);
        await tester.pump();

        final checkboxFinder = find.byKey(const Key('code-matches-checkbox'));
        await tester.tap(checkboxFinder);
        await tester.pump();
        await tester.tap(checkboxFinder);
        await tester.pump();

        expect(
          tester
              .widget<ElevatedButton>(
                find.widgetWithText(ElevatedButton, 'Approve'),
              )
              .onPressed,
          isNull,
        );
      });
    });

    testWidgets(
      'rejecting needs no checkbox, and still asks "are you sure?" first',
      (tester) async {
        await tester.runAsync(() async {
          await createPending();
          await pump(tester);
          await tester.pump();

          await tester.tap(find.widgetWithText(OutlinedButton, 'Reject'));
          await tester.pump();
          expect(find.text('Reject this partnership?'), findsOneWidget);

          await tester.tap(find.widgetWithText(FilledButton, 'Reject'));
          await pumpUntil(
            tester,
            () => find
                .widgetWithText(OutlinedButton, 'Reject')
                .evaluate()
                .isEmpty,
          );

          final saved = [
            for (final text in await store.savedTexts(partnership))
              Record.fromJson(jsonDecode(text) as Map<String, dynamic>),
          ];
          expect(
            saved.where(
              (r) => r.type == 'reject' && r.refersTo == testId('partnership'),
            ),
            hasLength(1),
          );
        });
      },
    );

    testWidgets('already answered by a write made elsewhere', (tester) async {
      await tester.runAsync(() async {
        await createPending();
        final answered = await managerWriter().answer(
          testId('partnership'),
          approve: true,
        );
        expect(answered.record, isNotNull);

        await pump(tester);
        await tester.pump();

        expect(find.text('This was already answered.'), findsOneWidget);
        expect(find.widgetWithText(ElevatedButton, 'Approve'), findsNothing);
        expect(find.widgetWithText(OutlinedButton, 'Reject'), findsNothing);
      });
    });

    testWidgets(
      'disables both buttons for the whole time a write is in flight',
      (tester) async {
        await tester.runAsync(() async {
          await createPending();
          final gate = Completer<void>();
          await pump(
            tester,
            writerOverride: managerWriter(beforeSign: () => gate.future),
          );
          await tester.pump();

          await tester.tap(find.byKey(const Key('code-matches-checkbox')));
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
