import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mobile/join/join_code.dart';
import 'package:mobile/onboarding/partnership_setup.dart';
import 'package:mobile/storage/record_store.dart';
import 'package:mobile/storage/record_writer.dart';
import 'package:mobile/storage/token_store.dart';
import 'package:mobile/sync/device_session.dart';
import 'package:mobile/sync/relay_client.dart';
import 'package:mobile/sync/sync_runner.dart';
import 'package:path/path.dart' as p;
import 'package:qirad_core/qirad_core.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fake_relay.dart';
import 'support/fake_secret_store.dart';

/// A full month, on two phones, every write through [RecordWriter] exactly
/// as the real forms and inbox call it — not hand-built records. This is the
/// scenario from the Phase 7 audit: it is the one place that checks the
/// creation forms, the inbox answer path and the budget-refusal rule
/// (decision 2026-10-11) all agree on the same numbers.
///
/// By default the relay is [FakeRelay]. With `QIRAD_REAL_RELAY=1` the same
/// scenario runs against a real relay at `QIRAD_RELAY_URL` (default
/// `http://127.0.0.1:8765`), the same way as `two_device_sync_test.dart`.
final _useRealRelay = Platform.environment['QIRAD_REAL_RELAY'] == '1';
final _realRelayUrl =
    Platform.environment['QIRAD_RELAY_URL'] ?? 'http://127.0.0.1:8765';

void main() {
  setUpAll(sqfliteFfiInit);

  group(
    _useRealRelay ? 'the month scenario, real relay' : 'the month scenario, '
        'fake relay',
    () {
      late Directory dir;
      late FakeRelay fake;

      setUp(() async {
        dir = await Directory.systemTemp.createTemp('qirad_month');
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
        'investor 60/40, a budget, a refused over-budget expense, a '
        'reversed typo, a future ratio change and a settlement all land the '
        'same on both phones',
        () async {
          final investorKeys = await generateEd25519KeyPair();
          final managerKeys = await generateEd25519KeyPair();
          final investorPhone = await phone('investor', investorKeys);
          final managerPhone = await phone('manager', managerKeys);

          // 1. The investor creates the partnership at 60/40 and syncs.
          final partnership = await createPartnership(
            investorKeys: investorKeys,
            managerKey: managerKeys.publicKeyBase64Url,
            investorPercent: 60,
            store: investorPhone.store,
          );
          final investorWriter = RecordWriter.forPartnership(
            keys: investorKeys,
            partnership: partnership,
            store: investorPhone.store,
          );
          await investorPhone.syncComplete(partnership);

          // 2. The manager joins from the investor's code and syncs down the
          // create, then approves it through the inbox answer path.
          final code = JoinCode.parse(
            JoinCode(
              partnership: partnership,
              investorKey: investorKeys.publicKeyBase64Url,
            ).encode(),
          );
          await joinPartnership(
            code: code,
            store: managerPhone.store,
            ownKeys: managerKeys,
          );
          await managerPhone.syncComplete(partnership);
          final managerWriter = RecordWriter.forPartnership(
            keys: managerKeys,
            partnership: partnership,
            store: managerPhone.store,
          );
          final approveCreate = await managerWriter.answer(
            partnership,
            approve: true,
          );
          expect(approveCreate.record, isNotNull);
          await managerPhone.syncComplete(partnership);
          await investorPhone.syncComplete(partnership);

          // 3. The investor invests Rs 1,000,000.
          final invest = await investorWriter.proposeInvest(
            amount: 100000000,
          );
          expect(invest.record, isNotNull);
          await investorPhone.syncComplete(partnership);
          await managerPhone.syncComplete(partnership);

          // 4. The manager proposes a Rs 300,000 budget for herself; the
          // investor approves it.
          final budget = await managerWriter.proposeBudget(
            amount: 30000000,
            grantee: managerKeys.publicKeyBase64Url,
          );
          expect(budget.record, isNotNull);
          await managerPhone.syncComplete(partnership);
          await investorPhone.syncComplete(partnership);
          final budgetPreview = budgetConsent(
            investorPhone.store.validatorFor(partnership).usableRecords,
            partnershipKeys: {
              investorKeys.publicKeyBase64Url,
              managerKeys.publicKeyBase64Url,
            },
            proposal: budget.record!,
          );
          final approveBudget = await investorWriter.answer(
            budget.record!.id,
            approve: true,
            shownBudget: budgetPreview,
          );
          expect(approveBudget.record, isNotNull);
          await investorPhone.syncComplete(partnership);
          await managerPhone.syncComplete(partnership);

          // 5. The manager works offline: no sync between any of these.
          final expense1 = await managerWriter.proposeExpense(
            amount: 20000000, // Rs 200,000
            budgetId: budget.record!.id,
          );
          expect(expense1.record, isNotNull);

          final sale = await managerWriter.proposeSale(amount: 26000000);
          expect(sale.record, isNotNull); // Rs 260,000

          final expense2 = await managerWriter.proposeExpense(
            amount: 5000000, // Rs 50,000
            budgetId: budget.record!.id,
          );
          expect(expense2.record, isNotNull);

          // Rs 300,000 granted, Rs 250,000 spent: Rs 50,000 left. Rs 80,000
          // is refused, and nothing is written for it (decision 2026-10-11).
          final refused = await managerWriter.proposeExpense(
            amount: 8000000,
            budgetId: budget.record!.id,
          );
          expect(refused.record, isNull);
          expect(refused.refusal, WriteRefusal.overBudget);
          expect(refused.budgetLeft, 5000000);

          final typo = await managerWriter.proposeExpense(
            amount: 500000, // Rs 5,000, a typo
            budgetId: budget.record!.id,
          );
          expect(typo.record, isNotNull);

          final reversal = await managerWriter.proposeReversal(
            targetId: typo.record!.id,
          );
          expect(reversal.record, isNotNull);

          final expense3 = await managerWriter.proposeExpense(
            amount: 50000, // Rs 500
            budgetId: budget.record!.id,
          );
          expect(expense3.record, isNotNull);

          // 6. The manager proposes a 50/50 ratio with a future start; the
          // investor approves it. This needs one sync round each way.
          final ratio = await managerWriter.proposeRatio(
            investorPercent: 50,
            managerPercent: 50,
            effectiveFrom: '2026-11-01',
          );
          expect(ratio.record, isNotNull);
          await managerPhone.syncComplete(partnership);
          await investorPhone.syncComplete(partnership);
          final ratioPreview = ratioConsent(
            investorPhone.store.validatorFor(partnership).usableRecords,
            partnershipKeys: {
              investorKeys.publicKeyBase64Url,
              managerKeys.publicKeyBase64Url,
            },
            proposal: ratio.record!,
          );
          final approveRatio = await investorWriter.answer(
            ratio.record!.id,
            approve: true,
            shownRatio: ratioPreview,
          );
          expect(approveRatio.record, isNotNull);
          await investorPhone.syncComplete(partnership);
          await managerPhone.syncComplete(partnership);

          // 7. Sync, then the manager proposes a settlement; the investor
          // approves it. The 50/50 change has a future effectiveFrom, so it
          // applies only after this settlement — this one still splits 60/40.
          await managerPhone.syncComplete(partnership);
          await investorPhone.syncComplete(partnership);
          final settlement = await managerWriter.proposeSettlement();
          expect(settlement.record, isNotNull);
          await managerPhone.syncComplete(partnership);
          await investorPhone.syncComplete(partnership);
          final settlementPreview = settlementConsent(
            investorPhone.store.validatorFor(partnership).usableRecords,
            partnershipKeys: {
              investorKeys.publicKeyBase64Url,
              managerKeys.publicKeyBase64Url,
            },
            proposal: settlement.record!,
            answer: buildRecord(
              ledger: investorPhone.store
                  .validatorFor(partnership)
                  .usableRecords,
              author: investorKeys.publicKeyBase64Url,
              partnership: partnership,
              id: 'preview-of-the-settlement-answer',
              type: 'approve',
              body: const {},
              time: '2026-10-11T10:00:00Z',
              refersTo: settlement.record!.id,
            ),
          );
          final approveSettlement = await investorWriter.answer(
            settlement.record!.id,
            approve: true,
            shownSettlement: settlementPreview,
          );
          expect(approveSettlement.record, isNotNull);
          await investorPhone.syncComplete(partnership);
          await managerPhone.syncComplete(partnership);

          // 8. Convergence: identical records, identical calculations.
          final investorView = await investorPhone.view(
            partnership,
            investorKeys,
            managerKeys,
          );
          final managerView = await managerPhone.view(
            partnership,
            investorKeys,
            managerKeys,
          );

          expect(managerView.records, investorView.records);
          expect(managerView.summary, investorView.summary);
          expect(investorView.summary, {
            'result': 950000, // Rs 9,500
            'ratio': 'investor 60 : manager 40',
            'investorShare': 570000, // Rs 5,700
            'managerShare': 380000, // Rs 3,800
            'cashBalance': 100950000, // Rs 1,009,500
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
    // The settled period's own ratio and shares (spec 6.7, decision
    // 2026-10-05): a ratio change approved during a period applies to the
    // *next* period, not the one it was approved in, so this is not the same
    // as the naive "ratio active right now".
    final settled = periodShares(
      usable,
      partnershipKeys: {
        investor.publicKeyBase64Url,
        manager.publicKeyBase64Url,
      },
    ).firstWhere((p) => !p.open);

    final records = await store.savedTexts(partnership);
    records.sort();
    return PhoneView(records, {
      'result': settled.result,
      'ratio': settled.ratio.toString(),
      'investorShare': settled.shares.investor,
      'managerShare': settled.shares.manager,
      'cashBalance': money.cashBalance,
    });
  }
}

/// What one phone shows after syncing.
class PhoneView {
  const PhoneView(this.records, this.summary);

  final List<String> records;
  final Map<String, Object?> summary;
}
