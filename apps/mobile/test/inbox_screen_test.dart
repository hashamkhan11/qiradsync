import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/inbox/inbox_screen.dart';
import 'package:mobile/storage/record_store.dart';
import 'package:mobile/storage/record_writer.dart';
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
    dir = await Directory.systemTemp.createTemp('qirad_inbox_screen_test');
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
  }) async {
    final unsigned = buildRecord(
      ledger: chain,
      author: keys.publicKeyBase64Url,
      partnership: partnership,
      id: testId(id),
      type: type,
      body: body,
      time: '2026-10-08T10:00:00Z',
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

  testWidgets('lists a pending settlement and opens it on tap', (tester) async {
    await tester.runAsync(() async {
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
      await receive(
        await write(
          manager,
          managerChain,
          id: 's1',
          type: 'settlement',
          body: {
            'cut': {
              investor.publicKeyBase64Url: 1,
              manager.publicKeyBase64Url: 1,
            },
          },
        ),
      );
      await store.saveRelayVector(partnership, {
        investor.publicKeyBase64Url: 1,
        manager.publicKeyBase64Url: 1,
      });
    });

    await tester.binding.setSurfaceSize(const Size(800, 1600));
    await tester.pumpWidget(
      MaterialApp(
        home: InboxScreen(
          store: store,
          writer: RecordWriter(
            keys: investor,
            partnership: partnership,
            store: store,
          ),
          myKey: investor.publicKeyBase64Url,
          partnership: partnership,
          onSyncNow: () async {},
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Settlement proposal'), findsOneWidget);
    expect(find.text('Nothing is waiting for you.'), findsNothing);

    await tester.tap(find.text('Settlement proposal'));
    await tester.pumpAndSettle();

    expect(
      find.text('Settlement'),
      findsOneWidget,
    ); // the confirm screen's title
  });

  testWidgets('says there is nothing waiting when the inbox is empty', (
    tester,
  ) async {
    await tester.runAsync(() async {
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
    });

    await tester.pumpWidget(
      MaterialApp(
        home: InboxScreen(
          store: store,
          writer: RecordWriter(
            keys: investor,
            partnership: partnership,
            store: store,
          ),
          myKey: investor.publicKeyBase64Url,
          partnership: partnership,
          onSyncNow: () async {},
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Nothing is waiting for you.'), findsOneWidget);
  });
}
