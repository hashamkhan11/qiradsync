import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mobile/join/join_code.dart';
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
import 'support/test_ids.dart';

/// Two phones, one investor and one manager, edit offline and sync through a
/// relay. Both must end with the same records and the same calculations.
///
/// By default the relay is [FakeRelay]. With `QIRAD_REAL_RELAY=1` the same
/// scenario runs against a real relay at `QIRAD_RELAY_URL` (default
/// `http://127.0.0.1:8765`). The shell starts that relay on a fresh SQLite
/// database first. To run it locally, from `relay/`:
///
/// ```
/// touch database/integration.sqlite
/// DB_DATABASE=$PWD/database/integration.sqlite php artisan migrate:fresh --force
/// DB_DATABASE=$PWD/database/integration.sqlite php artisan serve --port=8765
/// ```
///
/// Then, from `apps/mobile/`: `QIRAD_REAL_RELAY=1 flutter test test/two_device_sync_test.dart`
final _useRealRelay = Platform.environment['QIRAD_REAL_RELAY'] == '1';
final _realRelayUrl =
    Platform.environment['QIRAD_RELAY_URL'] ?? 'http://127.0.0.1:8765';

void main() {
  setUpAll(sqfliteFfiInit);

  group(
    _useRealRelay ? 'two devices, real relay' : 'two devices, fake relay',
    () {
      late Directory dir;
      late FakeRelay fake;

      setUp(() async {
        dir = await Directory.systemTemp.createTemp('qirad_two_devices');
        fake = FakeRelay();
      });

      tearDown(() async {
        await dir.delete(recursive: true);
      });

      RelayClient relay() => _useRealRelay
          ? RelayClient(baseUrl: _realRelayUrl, httpClient: http.Client())
          : RelayClient(baseUrl: 'https://relay.test', httpClient: fake.client);

      Future<Phone> phone(String name, Ed25519KeyPair keys) async {
        final client = relay();
        final store = await RecordStore.open(
          factory: databaseFactoryFfi,
          path: p.join(dir.path, '$name.db'),
        );
        // The device key is the partner's identity key. The relay checks that
        // the partnership's first record comes from the investor's device.
        final session = DeviceSession(
          keys: keys,
          relay: client,
          tokens: TokenStore(FakeSecretStore()),
        );
        return Phone(
          keys: keys,
          store: store,
          runner: SyncRunner(store: store, relay: client, session: session),
        );
      }

      test(
        'after offline edits on both phones, the calculations are identical',
        () async {
          // A unique id per run, so a re-run against the same relay works.
          final partnership = testId(
            'two-devices-${DateTime.now().microsecondsSinceEpoch}',
          );
          final investor = await generateEd25519KeyPair();
          final manager = await generateEd25519KeyPair();
          final investorWriter = Writer(investor, partnership);
          final managerWriter = Writer(manager, partnership);

          final investorPhone = await phone('investor', investor);
          final managerPhone = await phone('manager', manager);

          // 1. The investor starts the partnership and records capital, then
          //    syncs. It knows the manager's key from the manager's QR code.
          await investorPhone.store.addPartnership(
            partnership,
            investorKey: investor.publicKeyBase64Url,
            managerKey: manager.publicKeyBase64Url,
          );
          await investorPhone.add(
            await investorWriter.write(partnership, 'partnership_create', {
              'investor': investor.publicKeyBase64Url,
              'manager': manager.publicKeyBase64Url,
              'ratio': {'investor': 60, 'manager': 40},
              'currency': 'PKR',
            }),
          );
          await investorPhone.add(
            await investorWriter.write(testId('invest-2'), 'invest', {
              'amount': 150000,
            }),
          );
          await investorPhone.syncComplete(partnership);

          // 2. The manager scans the join code and syncs. The phone checks the
          //    investor's key against the code before it pins it.
          final code = JoinCode.parse(
            JoinCode(
              partnership: partnership,
              investorKey: investor.publicKeyBase64Url,
            ).encode(),
          );
          await joinPartnership(
            code: code,
            store: managerPhone.store,
            ownKeys: manager,
          );
          await managerPhone.syncComplete(partnership);

          // 3. Offline edits. The manager approves the partnership, records a
          //    sale and proposes a budget. The investor records more capital.
          //    Neither phone waits for the other.
          await managerPhone.add(
            await managerWriter.write(
              testId('approve-1'),
              'approve',
              const {},
              refersTo: partnership,
            ),
          );
          await managerPhone.add(
            await managerWriter.write(testId('sale-2'), 'sale', {
              'amount': 50000,
            }),
          );
          await managerPhone.add(
            await managerWriter.write(testId('budget-3'), 'budget_proposal', {
              'grantee': manager.publicKeyBase64Url,
              'amount': 30000,
            }),
          );
          await investorPhone.add(
            await investorWriter.write(testId('invest-3'), 'invest', {
              'amount': 20000,
            }),
          );

          // 4. Both sync. Now the investor has the budget and can approve it.
          await managerPhone.syncComplete(partnership);
          await investorPhone.syncComplete(partnership);
          await investorPhone.add(
            await investorWriter.write(
              testId('approve-4'),
              'approve',
              const {},
              refersTo: testId('budget-3'),
            ),
          );
          await investorPhone.syncComplete(partnership);

          // 5. The manager gets the approval, then spends from the budget.
          await managerPhone.syncComplete(partnership);
          await managerPhone.add(
            await managerWriter.write(testId('expense-5'), 'expense', {
              'amount': 10000,
              'receiptHash': null,
            }, refersTo: testId('budget-3')),
          );
          await managerPhone.syncComplete(partnership);
          await investorPhone.syncComplete(partnership);

          // 6. Convergence: same saved records, same calculations.
          final investorView = await investorPhone.view(
            partnership,
            investor,
            manager,
          );
          final managerView = await managerPhone.view(
            partnership,
            investor,
            manager,
          );

          expect(managerView.records, investorView.records);
          expect(managerView.summary, investorView.summary);
          expect(investorView.summary, {
            'capital': 170000,
            'cashBalance': 210000,
            'result': 40000,
            'profitPaid': 0,
            'budgetLeft': {testId('budget-3'): 20000},
            'ratio': 'investor 60 : manager 40',
            'investorShare': 24000,
            'managerShare': 16000,
            testId('expense-5'): 'valid',
          });

          await investorPhone.store.close();
          await managerPhone.store.close();
        },
      );
    },
  );
}

/// One partner's phone: its keys, its own store, and its sync runner.
class Phone {
  Phone({required this.keys, required this.store, required this.runner});

  final Ed25519KeyPair keys;
  final RecordStore store;
  final SyncRunner runner;

  /// Saves a record made on this phone. It must be accepted, or the test is
  /// wrong, so the check is strict.
  Future<void> add(String text) async {
    expect(await store.receive(text), ReceiveOutcome.accepted);
  }

  /// Syncs once, and fails unless the relay's vector matched for every author.
  Future<void> syncComplete(String partnership) async {
    final result = await runner.run(partnership);
    expect(result.complete, isTrue, reason: 'sync left records behind');
  }

  /// The saved texts and the calculated results, as this phone sees them.
  Future<PhoneView> view(
    String partnership,
    Ed25519KeyPair investor,
    Ed25519KeyPair manager,
  ) async {
    final validator = store.validatorFor(partnership);
    final usable = validator.usableRecords.toList();
    final effectiveness = computeEffective(
      usable,
      partnershipKeys: {
        investor.publicKeyBase64Url,
        manager.publicKeyBase64Url,
      },
    );
    final money = computeMoney(usable, effectiveness: effectiveness);
    final ratio = activeRatio(
      usable,
      effectiveness: effectiveness,
      date: '2026-10-03',
    )!;
    final shares = splitResult(
      money.result,
      investorPercent: ratio.investor,
      managerPercent: ratio.manager,
    );

    final records = await store.savedTexts(partnership);
    records.sort();
    return PhoneView(records, {
      'capital': money.capital,
      'cashBalance': money.cashBalance,
      'result': money.result,
      'profitPaid': money.profitPaid,
      'budgetLeft': money.budgetLeft,
      'ratio': ratio.toString(),
      'investorShare': shares.investor,
      'managerShare': shares.manager,
      testId('expense-5'):
          effectiveness.expenseStatus[testId('expense-5')]!.name,
    });
  }
}

/// What one phone shows after syncing.
class PhoneView {
  const PhoneView(this.records, this.summary);

  final List<String> records;
  final Map<String, Object?> summary;
}

/// Builds signed records for one author, with the chain (seq and prev_hash)
/// kept in order, as a phone does when it writes its own records.
class Writer {
  Writer(this.keys, this.partnership);

  final Ed25519KeyPair keys;
  final String partnership;

  int _seq = 0;
  String _prevHash = '0' * 64;

  Future<String> write(
    String id,
    String type,
    Map<String, Object?> body, {
    String? refersTo,
  }) async {
    _seq++;
    final unsigned = Record(
      v: 1,
      id: id,
      partnership: partnership,
      author: keys.publicKeyBase64Url,
      seq: _seq,
      prevHash: _prevHash,
      type: type,
      body: body,
      refersTo: refersTo,
      note: '',
      time: '2026-10-03T10:00:00Z',
      sig: '',
    );
    final text = canonicalJson((await signRecord(unsigned, keys)).toJson());
    // The next record in this chain points at this one, by its hash.
    _prevHash = recordHash(jsonDecode(text) as Map<String, dynamic>);
    return text;
  }
}
