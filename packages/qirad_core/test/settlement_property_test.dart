import 'dart:math';

import 'package:qirad_core/qirad_core.dart';
import 'package:test/test.dart';

import 'support/cut_helper.dart';
import 'support/partnership_fixture.dart';
import 'support/test_ids.dart';

/// The story from spec 6.7: two settlements, a correction by the investor's
/// reversal, and a profit withdrawal. The records are signed once and reused in
/// every run, so the runs differ only in arrival order.
Future<List<Record>> _story() async {
  final investor = ChainAuthor(await generateEd25519KeyPair());
  final manager = ChainAuthor(await generateEd25519KeyPair());
  final partnershipId = testId('partnership-story');
  final create = await investor.next(
    partnership: partnershipId,
    type: 'partnership_create',
    id: partnershipId,
    body: {
      'investor': investor.key,
      'manager': manager.key,
      'ratio': {'investor': 60, 'manager': 40},
      'currency': 'PKR',
    },
  );
  // Spec section 5: until the create is active, nothing else is effective.
  final approveCreate = await manager.next(
    partnership: partnershipId,
    type: 'approve',
    refersTo: create.id,
  );
  final budget = await investor.next(
    partnership: partnershipId,
    type: 'budget_proposal',
    body: {'grantee': manager.key, 'amount': 10000},
  );
  final withdraw = await investor.next(
    partnership: partnershipId,
    type: 'withdraw_request',
    body: {'amount': 500, 'kind': 'profit'},
  );
  final consent = await manager.next(
    partnership: partnershipId,
    type: 'approve',
    refersTo: budget.id,
  );
  final sale600 = await manager.next(
    partnership: partnershipId,
    type: 'sale',
    body: {'amount': 600},
  );
  final sale165 = await manager.next(
    partnership: partnershipId,
    type: 'sale',
    body: {'amount': 165},
  );
  final expense = await manager.next(
    partnership: partnershipId,
    type: 'expense',
    refersTo: budget.id,
    body: {'amount': 165, 'receiptHash': null},
  );
  final approveWithdraw = await manager.next(
    partnership: partnershipId,
    type: 'approve',
    refersTo: withdraw.id,
  );
  final s1 = await manager.next(
    partnership: partnershipId,
    type: settlementType,
    body: {
      'cut': cutUpTo(
        investor,
        manager,
        upToInvestor: withdraw,
        upToManager: approveWithdraw,
      ),
    },
  );
  final approveS1 = await investor.next(
    partnership: partnershipId,
    type: 'approve',
    refersTo: s1.id,
  );
  final reversal = await manager.next(
    partnership: partnershipId,
    type: 'reversal',
    refersTo: sale165.id,
  );
  final approveReversal = await investor.next(
    partnership: partnershipId,
    type: 'approve',
    refersTo: reversal.id,
  );
  final s2 = await manager.next(
    partnership: partnershipId,
    type: settlementType,
    body: {
      'cut': cutUpTo(
        investor,
        manager,
        upToInvestor: approveReversal,
        upToManager: reversal,
      ),
    },
  );
  final approveS2 = await investor.next(
    partnership: partnershipId,
    type: 'approve',
    refersTo: s2.id,
  );
  return [
    create,
    approveCreate,
    budget,
    withdraw,
    consent,
    sale600,
    sale165,
    expense,
    approveWithdraw,
    s1,
    approveS1,
    reversal,
    approveReversal,
    s2,
    approveS2,
  ];
}

/// One line per period, without the open flag. Used by the purity test, where
/// the same period is open in one ledger and closed in another.
List<String> _periodLines(Iterable<Record> usable, Set<String> keys) => [
  for (final p in periodShares(usable, partnershipKeys: keys))
    'P${p.index} cut=${p.closingCut.values.toList()} '
        'ratio=${p.ratio.investor}/${p.ratio.manager} result=${p.result} '
        'shares=${p.shares.investor}/${p.shares.manager} '
        'correction=${p.correction.investor}/${p.correction.manager} '
        'deficit=${p.deficitAfter}',
];

/// Every result that must be the same on every phone, as one sorted text. A
/// difference anywhere makes the strings differ.
String _snapshot(Validator validator) {
  final keys = validator.partnershipKeys!;
  final usable = validator.usableRecords;
  final effectiveness = computeEffective(usable, partnershipKeys: keys);
  final settlements = [
    for (final s in effectiveness.settlements)
      '${s.record.id}=${s.state.name} cut=${s.cut.values.toList()}',
  ]..sort();
  final expenses = [
    for (final e in effectiveness.expenseStatus.entries)
      '${e.key}=${e.value.name}',
  ]..sort();
  final splits = [
    for (final e in withdrawalSplits(usable, partnershipKeys: keys).entries)
      '${e.key}: withdrawn=${e.value.withdrawn} '
          'ahead=${e.value.aheadOfSettled} owed=${e.value.owedBack}',
  ]..sort();
  final totals = [
    for (final e in totalProfitWithdrawn(usable, partnershipKeys: keys).entries)
      '${e.key}: total=${e.value}',
  ]..sort();
  return [
    ...settlements,
    ...expenses,
    ..._periodLines(usable, keys),
    ...splits,
    ...totals,
  ].join('\n');
}

Future<Validator> _receiveShuffled(List<Record> story, Random random) async {
  // The create must come first, because no other record is accepted before the
  // partnership is known. Everything else is shuffled.
  final rest = story.sublist(1);
  final shuffled = [...rest];
  shuffled.shuffle(random);
  // Duplicates must be ignored, whatever order they arrive in.
  for (var d = 0; d < 3; d++) {
    shuffled.insert(
      random.nextInt(shuffled.length + 1),
      rest[random.nextInt(rest.length)],
    );
  }

  final validator = Validator.unpinnedForTesting();
  await validator.receiveText(canonicalJson(story.first.toJson()));
  for (final record in shuffled) {
    await validator.receiveText(canonicalJson(record.toJson()));
  }
  return validator;
}

void main() {
  group(
    'settlement and period results do not depend on arrival order (spec 8)',
    () {
      test(
        '200 seeded shuffles with duplicates give the same settlements, periods, '
        'deficits, splits and totals',
        () async {
          final story = await _story();
          final inOrder = Validator.unpinnedForTesting();
          for (final record in story) {
            await inOrder.receiveText(canonicalJson(record.toJson()));
          }
          final baseline = _snapshot(inOrder);

          // Sanity: the baseline really holds both settlements, so the check
          // below compares something real.
          expect(baseline, contains('=effective'));
          expect(baseline, contains('owed=99'));

          final random = Random(1234);
          for (var run = 0; run < 200; run++) {
            final validator = await _receiveShuffled(story, random);
            expect(_snapshot(validator), baseline, reason: 'shuffle $run');
          }
        },
      );
    },
  );

  group('a settled period is a pure function of its cut (spec 6.7)', () {
    test(
      'the periods up to each settlement are the same when only the records in its cut are kept',
      () async {
        final story = await _story();
        final validator = Validator.unpinnedForTesting();
        for (final record in story) {
          await validator.receiveText(canonicalJson(record.toJson()));
        }
        final keys = validator.partnershipKeys!;
        final usable = validator.usableRecords;
        final full = _periodLines(usable, keys);
        final closedCount = periodShares(
          usable,
          partnershipKeys: keys,
        ).where((p) => !p.open).length;
        expect(closedCount, 2, reason: 'the story has two settlements');

        for (var k = 1; k <= closedCount; k++) {
          final closingCut = periodShares(
            usable,
            partnershipKeys: keys,
          )[k - 1].closingCut;
          // Only the records inside this period's cut, with nothing later.
          final kept = recordsInCut(usable, closingCut);
          final partial = _periodLines(kept, keys);

          // Periods 1..k must match exactly. Nothing after the cut may change
          // them, because they were calculated from the cut alone.
          expect(
            partial.take(k).toList(),
            full.take(k).toList(),
            reason: 'periods up to settlement $k',
          );
        }
      },
    );
  });
}
