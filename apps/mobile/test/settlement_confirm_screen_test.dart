import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/inbox/settlement_confirm_screen.dart';
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
    dir = await Directory.systemTemp.createTemp('qirad_settlement_screen_test');
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

  // Same small set of helpers as record_writer_test.dart: build and save
  // records the way a phone would, without going through the screen.
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

  /// Invest 1,000, sale 500: a settlement S1 with a real, non-empty result,
  /// ready for the investor to answer (mirrors record_writer_test.dart).
  Future<void> settlementReady() async {
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
    await receive(
      await write(
        manager,
        managerChain,
        id: 's1',
        type: 'settlement',
        body: {
          'cut': {
            investor.publicKeyBase64Url: 2,
            manager.publicKeyBase64Url: 1,
          },
        },
      ),
    );
    await syncedAs(investorSeq: 2, managerSeq: 1);
  }

  RecordWriter writer() =>
      RecordWriter(keys: investor, partnership: partnership, store: store);

  Future<void> pump(
    WidgetTester tester, {
    Future<void> Function()? onSyncNow,
  }) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    await tester.pumpWidget(
      MaterialApp(
        home: SettlementConfirmScreen(
          store: store,
          writer: writer(),
          myKey: investor.publicKeyBase64Url,
          partnership: partnership,
          targetId: testId('s1'),
          onSyncNow: onSyncNow ?? () async {},
        ),
      ),
    );
  }

  // Every test body runs inside one `runAsync` call, start to finish, with
  // plain `tester.pump()` after each real write. `testWidgets` otherwise
  // wraps the body in a fake-async zone, where sqflite's real (FFI) I/O can
  // never settle; `pumpAndSettle()` adds its own frame-timing heuristic on
  // top, which this mix of real I/O and fake time made unreliable (an
  // occasional real hang, not just a slow run). One real zone and one
  // explicit pump per step removes both problems.
  group('SettlementConfirmScreen (spec 6.7)', () {
    testWidgets('shows the period numbers and lets the investor approve', (
      tester,
    ) async {
      await tester.runAsync(() async {
        await settlementReady();
        await pump(tester);
        await tester.pump();

        // Result 500, split 60/40: investor 300, manager 200 (all in rupees).
        expect(find.text('Rs 500.00'), findsOneWidget);
        expect(find.text('Rs 300.00'), findsOneWidget);
        expect(find.text('Rs 200.00'), findsOneWidget);
        expect(find.text('60/40'), findsOneWidget);
        expect(find.widgetWithText(ElevatedButton, 'Approve'), findsOneWidget);

        await tester.tap(find.widgetWithText(ElevatedButton, 'Approve'));
        // The approve is a real write; wait for it to land (the screen then
        // pops, so the button disappears) instead of guessing a pump count.
        await pumpUntil(
          tester,
          () =>
              find.widgetWithText(ElevatedButton, 'Approve').evaluate().isEmpty,
        );

        // create, invest, sale, settlement, and now the investor's approve.
        expect(await store.savedTexts(partnership), hasLength(5));
      });
    });

    testWidgets(
      'blocks approve and highlights reject when the cut covers records '
      'that do not exist',
      (tester) async {
        await tester.runAsync(() async {
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
          // The investor's next seq is 3; a cut naming seq 5 can never exist.
          await receive(
            await write(
              manager,
              managerChain,
              id: 's1',
              type: 'settlement',
              body: {
                'cut': {
                  investor.publicKeyBase64Url: 5,
                  manager.publicKeyBase64Url: 0,
                },
              },
            ),
          );
          await syncedAs(investorSeq: 2, managerSeq: 1);
          await pump(tester);
          await tester.pump();

          expect(
            find.text('Covers investor records that do not exist. Reject it.'),
            findsOneWidget,
          );
          expect(find.widgetWithText(ElevatedButton, 'Approve'), findsNothing);
          expect(find.widgetWithText(FilledButton, 'Reject'), findsOneWidget);
        });
      },
    );

    testWidgets(
      'a chain-behind-relay refusal on approve shows a Sync now button',
      (tester) async {
        await tester.runAsync(() async {
          await settlementReady();
          await pump(tester);
          await tester.pump();

          // The relay now reports a higher seq than this phone holds for
          // itself, as if another sync had happened in the background.
          await syncedAs(investorSeq: 99, managerSeq: 1);

          await tester.tap(find.widgetWithText(ElevatedButton, 'Approve'));
          // The approve is refused after a real relay-vector read; wait for
          // the refusal to land and the Sync now banner to appear.
          await pumpUntil(
            tester,
            () => find
                .widgetWithText(FilledButton, 'Sync now')
                .evaluate()
                .isNotEmpty,
          );

          expect(find.widgetWithText(FilledButton, 'Sync now'), findsOneWidget);
          expect(find.widgetWithText(ElevatedButton, 'Approve'), findsNothing);

          // Re-pumping with a new onSyncNow does not give a fresh screen: with
          // no Key, Flutter keeps the same State, so _needsSync (set by the
          // refusal above) is still true and the Sync now banner still shows
          // with no Approve button, same as before this pump. This re-pump
          // only swaps in a callback we can observe.
          var synced = false;
          await pump(
            tester,
            onSyncNow: () async {
              synced = true;
            },
          );
          await tester.pump();

          expect(find.widgetWithText(FilledButton, 'Sync now'), findsOneWidget);
          expect(find.widgetWithText(ElevatedButton, 'Approve'), findsNothing);

          await tester.tap(find.widgetWithText(FilledButton, 'Sync now'));
          await pumpUntil(tester, () => synced);
          expect(synced, isTrue);
        });
      },
    );
  });
}
