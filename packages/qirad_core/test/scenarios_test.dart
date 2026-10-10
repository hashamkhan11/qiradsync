import 'dart:math';

import 'package:qirad_core/qirad_core.dart';
import 'package:test/test.dart';

import 'support/partnership_fixture.dart';

/// Everything a device would show, as one comparable string. Keys are sorted so
/// that map order cannot make two identical results look different.
String _snapshot(Validator validator) {
  final effectiveness = computeEffective(
    validator.usableRecords,
    partnershipKeys: validator.partnershipKeys!,
  );
  final money = computeMoney(
    validator.usableRecords,
    effectiveness: effectiveness,
  );
  final ratio = activeRatio(
    validator.usableRecords,
    effectiveness: effectiveness,
  );
  final effectiveIds = effectiveness.effectiveIds.toList()..sort();
  final statuses = [
    for (final e in effectiveness.expenseStatus.entries)
      '${e.key}=${e.value.name}',
  ]..sort();
  final budgets = [
    for (final e in money.budgetLeft.entries) '${e.key}=${e.value}',
  ]..sort();
  final reversals = [
    for (final e in effectiveness.invalidReversals.entries)
      '${e.key}=${e.value}',
  ]..sort();

  return [
    effectiveIds.join(','),
    statuses.join(','),
    budgets.join(','),
    reversals.join(','),
    money.capital,
    money.cashBalance,
    money.result,
    money.profitPaid,
    ratio,
  ].join('|');
}

/// The full story, signed in each author's own chain order.
class _Story {
  final List<Record> records; // In chain order, create first.
  final String budgetId;
  final String expenseOkId;
  final String expenseOverId;

  _Story({
    required this.records,
    required this.budgetId,
    required this.expenseOkId,
    required this.expenseOverId,
  });
}

Future<_Story> _buildStory() async {
  final (validator, investor, manager, partnershipId) =
      await setUpUnapprovedPartnership();
  final create = validator.usableRecords.singleWhere(
    (r) => r.type == 'partnership_create',
  );

  final approveCreate = await manager.next(
    partnership: partnershipId,
    type: 'approve',
    refersTo: create.id,
  );
  final invest = await investor.next(
    partnership: partnershipId,
    type: 'invest',
    body: {'amount': 10000},
  );
  final budget = await investor.next(
    partnership: partnershipId,
    type: 'budget_proposal',
    body: {'grantee': manager.key, 'amount': 5000},
  );
  final approveBudget = await manager.next(
    partnership: partnershipId,
    type: 'approve',
    refersTo: budget.id,
  );
  final sale = await manager.next(
    partnership: partnershipId,
    type: 'sale',
    body: {'amount': 4000},
  );
  final expenseOk = await manager.next(
    partnership: partnershipId,
    type: 'expense',
    body: {'amount': 3000, 'receiptHash': null},
    refersTo: budget.id,
  );
  // 3000 + 2500 is more than the 5000 budget, so this one is over budget.
  final expenseOver = await manager.next(
    partnership: partnershipId,
    type: 'expense',
    body: {'amount': 2500, 'receiptHash': null},
    refersTo: budget.id,
  );
  // The manager cancels their own first expense. Its 3000 goes back to the budget.
  final reversal = await manager.next(
    partnership: partnershipId,
    type: 'reversal',
    refersTo: expenseOk.id,
  );
  final withdraw = await investor.next(
    partnership: partnershipId,
    type: 'withdraw_request',
    body: {'amount': 500, 'kind': 'profit'},
  );
  final approveWithdraw = await manager.next(
    partnership: partnershipId,
    type: 'approve',
    refersTo: withdraw.id,
  );
  final ratioProposal = await investor.next(
    partnership: partnershipId,
    type: 'ratio_proposal',
    body: {
      'ratio': {'investor': 50, 'manager': 50},
      'effectiveFrom': '2026-11-01',
    },
  );
  final approveRatio = await manager.next(
    partnership: partnershipId,
    type: 'approve',
    refersTo: ratioProposal.id,
  );

  return _Story(
    records: [
      create,
      approveCreate,
      invest,
      budget,
      approveBudget,
      sale,
      expenseOk,
      expenseOver,
      reversal,
      withdraw,
      approveWithdraw,
      ratioProposal,
      approveRatio,
    ],
    budgetId: budget.id,
    expenseOkId: expenseOk.id,
    expenseOverId: expenseOver.id,
  );
}

Future<Validator> _receiveAll(List<Record> records) async {
  final validator = Validator.unpinnedForTesting();
  for (final record in records) {
    await validator.receiveText(canonicalJson(record.toJson()));
  }
  return validator;
}

void main() {
  group('full partnership scenario (spec sections 6.3 to 6.6)', () {
    test(
      'every total and the profit split match the hand-worked numbers',
      () async {
        final story = await _buildStory();
        final validator = await _receiveAll(story.records);
        final effectiveness = computeEffective(
          validator.usableRecords,
          partnershipKeys: validator.partnershipKeys!,
        );
        final money = computeMoney(
          validator.usableRecords,
          effectiveness: effectiveness,
        );

        // The first expense was counted, then reversed by its own author.
        expect(
          effectiveness.expenseStatus[story.expenseOkId],
          ExpenseStatus.valid,
        );
        // The second expense did not fit (3000 + 2500 > 5000), and stays that way.
        expect(
          effectiveness.expenseStatus[story.expenseOverId],
          ExpenseStatus.overBudget,
        );

        expect(money.capital, 10000);
        expect(money.result, 4000); // 4000 sales, no counted expenses
        expect(money.cashBalance, 13500); // 10000 + 4000 - 500 profit paid
        expect(money.profitPaid, 500);
        expect(money.budgetLeft, {story.budgetId: 5000});
      },
    );

    test(
      'the latest effective ratio splits all the profit, with no date',
      () async {
        final story = await _buildStory();
        final validator = await _receiveAll(story.records);
        final effectiveness = computeEffective(
          validator.usableRecords,
          partnershipKeys: validator.partnershipKeys!,
        );
        final money = computeMoney(
          validator.usableRecords,
          effectiveness: effectiveness,
        );

        // The 50/50 proposal is effective, so it applies to the whole result. It
        // is not split by date (hard rule 3). The known issue in docs/decisions.md
        // says profit earned before the change should keep 60/40. Settlement
        // will fix this and this expectation will change then.
        final ratio = activeRatio(
          validator.usableRecords,
          effectiveness: effectiveness,
        )!;
        expect(ratio.ratio, const Ratio(investor: 50, manager: 50));
        expect(ratio.agreedStart, '2026-11-01');
        final shares = splitResult(
          money.result,
          investorPercent: ratio.ratio.investor,
          managerPercent: ratio.ratio.manager,
        );
        expect(shares.manager, 2000);
        expect(shares.investor, 2000);
      },
    );
  });

  group('same records in any order, with duplicates (spec section 8)', () {
    test(
      '200 shuffled arrival orders, with duplicates, give identical results',
      () async {
        final story = await _buildStory();

        final baseline = _snapshot(await _receiveAll(story.records));

        // The partnership_create must come first: no other record is accepted
        // before the partnership is known. The rest is shuffled.
        final random = Random(1234);
        final rest = story.records.sublist(1);
        for (var run = 0; run < 200; run++) {
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
          await validator.receiveText(
            canonicalJson(story.records.first.toJson()),
          );
          for (final record in shuffled) {
            await validator.receiveText(canonicalJson(record.toJson()));
          }

          expect(_snapshot(validator), baseline, reason: 'shuffle $run');
        }
      },
    );
  });
}
