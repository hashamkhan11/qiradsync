import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
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

void main() {
  setUpAll(sqfliteFfiInit);

  late Directory dir;
  late SignedTexts texts;
  late FakeRelay relay;
  late RecordStore store;
  late RelayClient client;
  late TokenStore tokens;
  late DeviceSession session;
  late List<Duration> waits;

  setUp(() async {
    waits = [];
    dir = await Directory.systemTemp.createTemp('qirad_sync_test');
    texts = await SignedTexts.create();
    relay = FakeRelay();
    client = RelayClient(
      baseUrl: 'https://relay.test',
      httpClient: relay.client,
    );
    // The phone already registered: its token is saved, as after a restart.
    tokens = TokenStore(FakeSecretStore());
    await tokens.save('secret-token');
    session = DeviceSession(
      keys: await generateEd25519KeyPair(),
      relay: client,
      tokens: tokens,
    );
    store = await RecordStore.open(
      factory: databaseFactoryFfi,
      path: p.join(dir.path, 'records.db'),
    );
    // The partnership is registered, as when the user joins it.
    await store.addPartnership(
      'p1',
      investorKey: texts.investor.publicKeyBase64Url,
      managerKey: texts.manager.publicKeyBase64Url,
    );
  });

  tearDown(() async {
    await store.close();
    await dir.delete(recursive: true);
  });

  SyncRunner runner({int maxRepairRounds = 3}) {
    return SyncRunner(
      store: store,
      relay: client,
      session: session,
      maxRepairRounds: maxRepairRounds,
      // Records the wait instead of sleeping, so tests stay fast and exact.
      delay: (duration) async => waits.add(duration),
    );
  }

  test(
    'joining a partnership and syncing receives its partnership_create',
    () async {
      final create = await texts.partnershipCreate();
      relay.seed(create);

      final result = await runner().run('p1');

      expect(result.complete, isTrue);
      expect(await store.savedTexts('p1'), [create]);
      expect(store.versionVector('p1'), {texts.investor.publicKeyBase64Url: 1});
      expect(relay.lastAuthorization, 'Bearer secret-token');
    },
  );

  test(
    'the phone uploads what the relay lacks, with no repair needed',
    () async {
      final create = await texts.partnershipCreate();
      final invest2 = await texts.invest(
        id: 'invest-2',
        seq: 2,
        prevText: create,
      );
      await store.receive(create);
      await store.receive(invest2);

      final result = await runner().run('p1');

      expect(result.complete, isTrue);
      expect(result.repairRounds, 0);
      expect(relay.storedCount, 2);
    },
  );

  test('a gap on the relay is refilled by one repair round', () async {
    final create = await texts.partnershipCreate();
    final invest2 = await texts.invest(
      id: 'invest-2',
      seq: 2,
      prevText: create,
    );
    final invest3 = await texts.invest(
      id: 'invest-3',
      seq: 3,
      prevText: invest2,
    );
    await store.receive(create);
    await store.receive(invest2);
    await store.receive(invest3);
    // The relay loses invest-2 on the first upload. It keeps seq 1 and 3, so
    // its gap-aware vector says 1, and the phone must upload from seq 2 on.
    relay.dropOnce.add('invest-2');

    final result = await runner().run('p1');

    expect(result.complete, isTrue);
    expect(result.repairRounds, 1);
    expect(relay.storedCount, 3);
  });

  test(
    'a relay that never keeps records stops after three repair rounds',
    () async {
      final create = await texts.partnershipCreate();
      final invest2 = await texts.invest(
        id: 'invest-2',
        seq: 2,
        prevText: create,
      );
      await store.receive(create);
      await store.receive(invest2);
      relay.dropAll = true;

      final result = await runner().run('p1');

      expect(result.complete, isFalse);
      expect(result.repairRounds, 3);
      expect(relay.calls, 4, reason: 'one call, then three repair calls');
    },
  );

  test(
    'both versions of a conflict reach the phone and flag the manager',
    () async {
      final create = await texts.partnershipCreate();
      relay.seed(create);
      final approveA = await texts.approve(id: 'approve-5a', seq: 5);
      final approveB = await texts.approve(id: 'approve-5b', seq: 5);
      relay.seed(approveA);
      relay.seed(approveB);

      final result = await runner().run('p1');

      expect(result.complete, isTrue);
      expect(await store.savedTexts('p1'), containsAll([approveA, approveB]));
      expect(store.validatorFor('p1').equivocatingFromSeq, {
        texts.manager.publicKeyBase64Url: 5,
      });
    },
  );

  test('a record from the relay with a bad signature is not stored', () async {
    final create = await texts.partnershipCreate();
    final invest2 = await texts.invest(
      id: 'invest-2',
      seq: 2,
      prevText: create,
    );
    // Change the note after signing. The canonical form stays valid, so only
    // the signature check can catch it.
    final tampered = invest2.replaceFirst('"note":""', '"note":"changed"');
    relay.seed(create);
    relay.seed(tampered);

    await runner().run('p1');

    expect(await store.savedTexts('p1'), [create]);
  });

  test('a refused call throws and stores nothing', () async {
    relay.refuseWith = 403;
    relay.seed(await texts.partnershipCreate());

    await expectLater(
      runner().run('p1'),
      throwsA(isA<RelayRefused>().having((e) => e.status, 'status', 403)),
    );
    expect(await store.savedTexts('p1'), isEmpty);
  });

  test('a 403 is not answered by registering again', () async {
    relay.refuseWith = 403;

    await expectLater(runner().run('p1'), throwsA(isA<RelayRefused>()));
    expect(relay.registrations, 0);
  });

  test('a 401 registers once more and retries, so the sync completes', () async {
    relay.seed(await texts.partnershipCreate());
    // The relay only accepts tokens it issued. The saved one is not among them.
    relay.enforceTokens = true;

    final result = await runner().run('p1');

    expect(result.complete, isTrue);
    expect(relay.registrations, 1);
    expect(relay.lastAuthorization, 'Bearer token-1');
    expect(await tokens.load(), 'token-1');
    expect(await store.savedTexts('p1'), hasLength(1));
  });

  test('a second 401 in the same run stops with DeviceRejected', () async {
    relay.refuseWith = 401;

    await expectLater(runner().run('p1'), throwsA(isA<DeviceRejected>()));
    expect(relay.registrations, 1, reason: 'registered once, not in a loop');
    expect(relay.calls, 2, reason: 'the saved token, then the new one');
    expect(waits, isEmpty, reason: 'a rejected device is not retried');
  });

  group('retry with backoff (spec 7.3 step 6)', () {
    test('the wait doubles from 1 s and is capped at 30 s', () {
      expect(SyncRunner.backoffDelay(1), const Duration(seconds: 1));
      expect(SyncRunner.backoffDelay(2), const Duration(seconds: 2));
      expect(SyncRunner.backoffDelay(3), const Duration(seconds: 4));
      expect(SyncRunner.backoffDelay(5), const Duration(seconds: 16));
      expect(SyncRunner.backoffDelay(6), const Duration(seconds: 30));
      expect(SyncRunner.backoffDelay(20), const Duration(seconds: 30));
    });

    test(
      'a network failure is retried once after 1 s, then completes',
      () async {
        relay.seed(await texts.partnershipCreate());
        relay.networkFailures = 1;

        final result = await runner().run('p1');

        expect(result.complete, isTrue);
        expect(waits, [const Duration(seconds: 1)]);
        expect(relay.calls, 2, reason: 'the failed attempt, then the retry');
      },
    );

    test('the waits double across several failures: 1, 2, 4 s', () async {
      relay.seed(await texts.partnershipCreate());
      relay.networkFailures = 3;

      await runner().run('p1');

      expect(waits, [
        const Duration(seconds: 1),
        const Duration(seconds: 2),
        const Duration(seconds: 4),
      ]);
    });

    test('a relay 503 is retried like a network failure', () async {
      relay.seed(await texts.partnershipCreate());
      relay.serverErrors = 1;

      final result = await runner().run('p1');

      expect(result.complete, isTrue);
      expect(waits, [const Duration(seconds: 1)]);
    });

    test('gives up after 5 retries, with the last error', () async {
      relay.networkFailures = 100;

      await expectLater(
        runner().run('p1'),
        throwsA(isA<http.ClientException>()),
      );
      expect(waits, hasLength(5));
      expect(relay.calls, 6, reason: 'the first attempt and 5 retries');
    });

    test('a 403 is not retried', () async {
      relay.refuseWith = 403;

      await expectLater(runner().run('p1'), throwsA(isA<RelayRefused>()));
      expect(waits, isEmpty);
      expect(relay.calls, 1);
    });
  });
}
