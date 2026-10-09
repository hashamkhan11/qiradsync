import 'dart:async';
import 'dart:convert';
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
  /// partnership is active (spec section 5) and settlements can be answered.
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

  /// Invest 1,000, sale 500: a settlement S1 with a real, non-empty result,
  /// ready for the investor to answer (mirrors record_writer_test.dart).
  Future<void> settlementReady() async {
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
    await receive(
      await write(
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
      ),
    );
    await syncedAs(investorSeq: invest.seq, managerSeq: sale.seq);
  }

  /// The manager's very first record: a settlement proposing to close a
  /// period covering zero records from either partner (cut `{0, 0}`). This
  /// is a real, ordinary record — schema (spec section 5) only requires
  /// `cut` to be a two-key map. `approvalsInbox`'s block check (spec 6.7)
  /// now reuses `cutProblem` (cut rules 3-5: closed, dominating, not
  /// empty), so this settlement is blocked in the inbox itself: "This
  /// settlement covers nothing new. Reject it." Kept as a normal (not
  /// hand-built) fixture, since it is a genuine record the validator
  /// accepts — see docs/decisions.md, 2026-10-09.
  Future<Record> emptyCutSettlementReady() async {
    await startWithCreate();
    final s1 = await write(
      manager,
      managerChain,
      id: 's1',
      type: 'settlement',
      body: {
        'cut': {investor.publicKeyBase64Url: 0, manager.publicKeyBase64Url: 0},
      },
    );
    await receive(s1);
    await syncedAs(investorSeq: 1, managerSeq: 1);
    return s1;
  }

  RecordWriter writer({Future<void> Function()? beforeSign}) => RecordWriter(
    keys: investor,
    partnership: partnership,
    store: store,
    beforeSign: beforeSign,
  );

  Future<void> pump(
    WidgetTester tester, {
    Future<void> Function()? onSyncNow,
    RecordWriter? writerOverride,
    String? targetId,
  }) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    await tester.pumpWidget(
      MaterialApp(
        home: SettlementConfirmScreen(
          store: store,
          writer: writerOverride ?? writer(),
          myKey: investor.publicKeyBase64Url,
          partnership: partnership,
          targetId: targetId ?? testId('s1'),
          onSyncNow: onSyncNow ?? () async {},
        ),
      ),
    );
  }

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

        // create, approveCreate, invest, sale, settlement, and now the
        // investor's approve.
        expect(await store.savedTexts(partnership), hasLength(6));
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

    testWidgets(
      'no Approve, and Reject highlighted, when the settlement cut is empty',
      (tester) async {
        await tester.runAsync(() async {
          await emptyCutSettlementReady();
          await pump(tester);
          await tester.pump();

          expect(
            find.text('This settlement covers nothing new. Reject it.'),
            findsOneWidget,
          );
          expect(find.widgetWithText(ElevatedButton, 'Approve'), findsNothing);
          // Blocked for a reason that can never clear: Reject is
          // highlighted (destructive), the same as the other final blocks.
          expect(find.widgetWithText(FilledButton, 'Reject'), findsOneWidget);
          expect(find.widgetWithText(OutlinedButton, 'Reject'), findsNothing);
        });
      },
    );

    testWidgets(
      'disables both buttons for the whole time a write is in flight',
      (tester) async {
        await tester.runAsync(() async {
          await settlementReady();
          // A write that will not finish until the test says so, so the
          // disabled check cannot depend on how fast the real database
          // happens to be (no pump-count or real-delay guesswork).
          final gate = Completer<void>();
          await pump(
            tester,
            writerOverride: writer(beforeSign: () => gate.future),
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
        await settlementReady();
        await pump(tester);
        await tester.pump();

        await tester.tap(find.widgetWithText(OutlinedButton, 'Reject'));
        await tester.pump();
        expect(find.text('Reject this settlement?'), findsOneWidget);
        expect(find.text('This cannot be undone.'), findsOneWidget);

        // Cancel: the dialog closes, nothing is written.
        await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
        await tester.pump();
        expect(find.text('Reject this settlement?'), findsNothing);
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
        await settlementReady();
        await pump(tester);
        await tester.pump();

        final approve = find.widgetWithText(ElevatedButton, 'Approve');
        // No pump between the two taps: both land on the same build, where
        // the button is still enabled, the same way two real, fast taps
        // could both reach the handler before the first rebuild disables it.
        await tester.tap(approve);
        await tester.tap(approve);
        await pumpUntil(tester, () => approve.evaluate().isEmpty);

        // Exactly one approve was saved (create, approveCreate, invest,
        // sale, settlement, approve), and no two of my own records share a
        // seq: the second tap's write is refused as alreadyAnswered by the
        // serial queue, not raced into a fork.
        expect(await store.savedTexts(partnership), hasLength(6));
        final seqs = await mySeqs();
        expect(seqs, hasLength(seqs.toSet().length));
        // The second tap is refused as alreadyAnswered, but that refusal
        // never has anywhere to show: once the settlement is decided,
        // `build` always takes the early "This was already answered."
        // branch, which does not render `_message` at all, no matter which
        // tap's result lands first or second.
        expect(find.text('Already answered.'), findsNothing);
      });
    });
  });
}
