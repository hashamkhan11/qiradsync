import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/transactions/record_detail_screen.dart';
import 'package:mobile/transactions/transactions_screen.dart';
import 'package:mobile/storage/record_store.dart';
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
  late List<Record> investorChain;
  late List<Record> managerChain;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('qirad_transactions_test');
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

  /// The create is special: it is what pins the two partnership keys in the
  /// first place, so it goes through `startPartnership`, not plain `receive`
  /// (spec section 5).
  Future<Record> createPartnership() async {
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
    return create;
  }

  Future<void> pump(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    await tester.pumpWidget(
      MaterialApp(
        home: TransactionsScreen(store: store, partnership: partnership),
      ),
    );
  }

  testWidgets('shows every stored record, including one still pending', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final create = await createPartnership();
      // Spec section 5: nothing but the create itself is effective until
      // the manager approves it.
      await receive(
        await write(
          manager,
          managerChain,
          id: 'approve-create',
          type: 'approve',
          refersTo: create.id,
        ),
      );

      final invest = await write(
        investor,
        investorChain,
        id: 'invest-1',
        type: 'invest',
        body: const {'amount': 10000},
      );
      await receive(invest);

      final budget = await write(
        investor,
        investorChain,
        id: 'budget-1',
        type: 'budget_proposal',
        body: {'grantee': manager.publicKeyBase64Url, 'amount': 5000},
      );
      await receive(budget);
    });
    await pump(tester);

    expect(find.text('partnership create'), findsOneWidget);
    expect(find.text('invest'), findsOneWidget);
    expect(find.text('Rs 100.00'), findsOneWidget);
    expect(find.text('Investor · Effective'), findsNWidgets(2));
    expect(find.text('Manager · Effective'), findsOneWidget);
    expect(find.text('Investor · Pending approval'), findsOneWidget);
  });

  testWidgets('a chain-invalid record still shows, marked as such', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await createPartnership();

      final badChain = Record(
        v: 1,
        id: testId('bad-chain'),
        partnership: partnership,
        author: investor.publicKeyBase64Url,
        seq: 2,
        prevHash: 'a' * 64,
        type: 'invest',
        body: const {'amount': 10000},
        refersTo: null,
        note: '',
        time: '2026-10-08T10:00:00Z',
        sig: '',
      );
      final signed = await signRecord(badChain, investor);
      expect(
        await store.receive(canonicalJson(signed.toJson())),
        ReceiveOutcome.chainInvalid,
      );
    });
    await pump(tester);

    expect(find.text('Investor · Chain-invalid'), findsOneWidget);
  });

  testWidgets('tapping a record opens its detail screen', (tester) async {
    await tester.runAsync(createPartnership);
    await pump(tester);

    await tester.tap(find.text('partnership create'));
    await tester.pumpAndSettle();

    expect(find.byType(RecordDetailScreen), findsOneWidget);
    expect(find.text('Id'), findsOneWidget);
    expect(find.text('Seq'), findsOneWidget);
  });

  testWidgets('detail screen shows a signature fact and a tappable link', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final create = await createPartnership();
      await receive(
        await write(
          manager,
          managerChain,
          id: 'approve-create',
          type: 'approve',
          refersTo: create.id,
        ),
      );
    });
    await pump(tester);

    // Every stored record passed signature verification on receipt (spec
    // 6.1 step 2), so this fact is the same on every detail screen.
    await tester.tap(find.text('partnership create'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Valid'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    // The approve's "Refers to" is a link to the create it answers, since
    // this phone has that record.
    await tester.tap(find.text('approve'));
    await tester.pumpAndSettle();
    expect(find.text('partnership create (${testId('partnership')})'), findsOneWidget);

    await tester.tap(find.text('partnership create (${testId('partnership')})'));
    await tester.pumpAndSettle();
    expect(find.text('partnership create'), findsWidgets);
  });
}
