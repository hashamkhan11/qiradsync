import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/dashboard/dashboard_screen.dart';
import 'package:mobile/onboarding/partnership_setup.dart';
import 'package:mobile/storage/record_store.dart';
import 'package:path/path.dart' as p;
import 'package:qirad_core/qirad_core.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  late Directory dir;
  late RecordStore store;
  late Ed25519KeyPair investor;
  late Ed25519KeyPair manager;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('qirad_dashboard_test');
    store = await RecordStore.open(
      factory: databaseFactoryFfi,
      path: p.join(dir.path, 'records.db'),
    );
    investor = await generateEd25519KeyPair();
    manager = await generateEd25519KeyPair();
  });

  tearDown(() async {
    await store.close();
    await dir.delete(recursive: true);
  });

  Future<void> pumpDashboard(WidgetTester tester, String id) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    await tester.pumpWidget(
      MaterialApp(
        home: DashboardScreen(
          store: store,
          partnership: id,
          now: () => DateTime(2026, 10, 5, 9),
        ),
      ),
    );
  }

  /// Signs a record for [keys] with the given chain position.
  Future<String> signed(
    Ed25519KeyPair keys, {
    required String partnership,
    required int seq,
    required String prevHash,
    required String type,
    String id = '',
    Map<String, dynamic> body = const {},
    String? refersTo,
  }) async {
    final unsigned = Record(
      v: 1,
      id: id.isEmpty ? const Uuid().v4() : id,
      partnership: partnership,
      author: keys.publicKeyBase64Url,
      seq: seq,
      prevHash: prevHash,
      type: type,
      body: body,
      refersTo: refersTo,
      note: '',
      time: '2026-10-05T09:00:00Z',
      sig: '',
    );
    final record = await signRecord(unsigned, keys);
    return canonicalJson(record.toJson());
  }

  /// The investor's create is saved by createPartnership. The manager then
  /// approves it, and the investor proposes a 50/50 ratio from 2026-09-01,
  /// which the manager approves. Returns the partnership id.
  Future<String> partnershipWithRatioChange() async {
    final id = await createPartnership(
      investorKeys: investor,
      managerKey: manager.publicKeyBase64Url,
      investorPercent: 60,
      store: store,
    );
    final createText = (await store.savedTexts(id)).single;
    final createHash = recordHash(
      jsonDecode(createText) as Map<String, dynamic>,
    );
    final zeros = '0' * 64;

    final approveCreate = await signed(
      manager,
      partnership: id,
      seq: 1,
      prevHash: zeros,
      type: 'approve',
      refersTo: id,
    );
    final approveCreateHash = recordHash(
      jsonDecode(approveCreate) as Map<String, dynamic>,
    );
    expect(
      await store.receive(approveCreate),
      ReceiveOutcome.accepted,
      reason: "approveCreate",
    );

    final proposal = await signed(
      investor,
      partnership: id,
      seq: 2,
      prevHash: createHash,
      type: 'ratio_proposal',
      body: {
        'ratio': {'investor': 50, 'manager': 50},
        'effectiveFrom': '2026-09-01',
      },
    );
    final proposalId =
        (jsonDecode(proposal) as Map<String, dynamic>)['id'] as String;
    expect(
      await store.receive(proposal),
      ReceiveOutcome.accepted,
      reason: "proposal",
    );

    final approveProposal = await signed(
      manager,
      partnership: id,
      seq: 2,
      prevHash: approveCreateHash,
      type: 'approve',
      refersTo: proposalId,
    );
    expect(
      await store.receive(approveProposal),
      ReceiveOutcome.accepted,
      reason: "approveProposal",
    );
    return id;
  }

  testWidgets('before the manager approves, it says there is no ratio yet', (
    tester,
  ) async {
    final id = await tester.runAsync(
      () => createPartnership(
        investorKeys: investor,
        managerKey: manager.publicKeyBase64Url,
        investorPercent: 60,
        store: store,
      ),
    );
    await pumpDashboard(tester, id!);

    expect(find.text('Rs 0.00'), findsNWidgets(3));
    expect(
      find.text('No active ratio yet. The manager must approve the start.'),
      findsOneWidget,
    );
    expect(find.text('Ratio shown for 2026-10-05 (today)'), findsOneWidget);
    expect(find.textContaining('may not match the contract'), findsNothing);
  });

  testWidgets('after a ratio change, it warns that the split may not match', (
    tester,
  ) async {
    final id = await tester.runAsync(partnershipWithRatioChange);
    await pumpDashboard(tester, id!);

    expect(find.text('Investor (50%)'), findsOneWidget);
    expect(find.text('Manager (50%)'), findsOneWidget);
    expect(find.textContaining('may not match the contract'), findsOneWidget);
  });
}
