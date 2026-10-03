import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/storage/record_store.dart';
import 'package:mobile/storage/token_store.dart';
import 'package:mobile/sync/device_session.dart';
import 'package:mobile/sync/relay_client.dart';
import 'package:mobile/sync/sync_runner.dart';
import 'package:path/path.dart' as p;
import 'package:qirad_core/qirad_core.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fake_relay.dart';
import 'support/fake_secret_store.dart';
import 'support/signed_texts.dart';
import 'support/test_ids.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  // Spec 8, "Sync recovery": wipe the relay's database, then run the next sync
  // from either phone. The relay must end up holding every record that exists
  // on either phone. Compare-and-repair (spec 7.3) is what makes this true.
  test(
    'after the relay loses its data, the next sync from either phone refills it',
    () async {
      final dir = await Directory.systemTemp.createTemp('qirad_recovery_test');
      addTearDown(() => dir.delete(recursive: true));
      final texts = await SignedTexts.create();
      final relay = FakeRelay();
      final client = RelayClient(
        baseUrl: 'https://relay.test',
        httpClient: relay.client,
      );
      final investorPhone = await _openPhone(dir, 'investor', texts, client);
      final managerPhone = await _openPhone(dir, 'manager', texts, client);
      addTearDown(investorPhone.store.close);
      addTearDown(managerPhone.store.close);

      // The investor writes three records; the manager writes one.
      final create = await texts.partnershipCreate();
      final invest2 = await texts.invest(
        id: testId('invest-2'),
        seq: 2,
        prevText: create,
      );
      final invest3 = await texts.invest(
        id: testId('invest-3'),
        seq: 3,
        prevText: invest2,
      );
      final approve = await texts.approve(id: testId('approve-1'), seq: 1);
      await investorPhone.store.receive(create);
      await investorPhone.store.receive(invest2);
      await investorPhone.store.receive(invest3);

      // The manager can only write once it has the partnership_create, so the
      // investor uploads first and the manager's phone then receives the chain.
      await investorPhone.runner.run(testId('p1'));
      await managerPhone.runner.run(testId('p1'));
      expect(
        await managerPhone.store.receive(approve),
        ReceiveOutcome.accepted,
      );
      await managerPhone.runner.run(testId('p1'));
      await investorPhone.runner.run(testId('p1'));
      expect(await investorPhone.store.savedTexts(testId('p1')), hasLength(4));
      expect(await managerPhone.store.savedTexts(testId('p1')), hasLength(4));
      expect(relay.storedCount, 4);

      // The relay loses everything. Then the investor's phone syncs.
      relay.wipe();
      expect(relay.storedCount, 0);
      final fromInvestor = await investorPhone.runner.run(testId('p1'));

      expect(fromInvestor.complete, isTrue);
      expect(relay.storedCount, 4, reason: 'every record is back on the relay');

      // The same must hold when the manager's phone syncs after a second loss.
      relay.wipe();
      final fromManager = await managerPhone.runner.run(testId('p1'));

      expect(fromManager.complete, isTrue);
      expect(relay.storedCount, 4, reason: 'every record is back on the relay');
    },
  );
}

/// One phone for this test: its own database, its own token, and a sync runner.
class _Phone {
  _Phone(this.store, this.runner);

  final RecordStore store;
  final SyncRunner runner;
}

Future<_Phone> _openPhone(
  Directory dir,
  String name,
  SignedTexts texts,
  RelayClient client,
) async {
  final tokens = TokenStore(FakeSecretStore());
  await tokens.save('secret-token');
  final session = DeviceSession(
    keys: await generateEd25519KeyPair(),
    relay: client,
    tokens: tokens,
  );
  final store = await RecordStore.open(
    factory: databaseFactoryFfi,
    path: p.join(dir.path, '$name.db'),
  );
  await store.addPartnership(
    testId('p1'),
    investorKey: texts.investor.publicKeyBase64Url,
    managerKey: texts.manager.publicKeyBase64Url,
  );
  final runner = SyncRunner(
    store: store,
    relay: client,
    session: session,
    delay: (_) async {},
  );
  return _Phone(store, runner);
}
