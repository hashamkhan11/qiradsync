import 'dart:math';

import 'package:qirad_core/qirad_core.dart';
import 'package:test/test.dart';

import 'support/partnership_fixture.dart';

Future<MoneySummary> _money(Validator validator) async {
  final effectiveness = computeEffective(
    validator.usableRecords,
    partnershipKeys: validator.partnershipKeys!,
  );
  return computeMoney(validator.usableRecords, effectiveness: effectiveness);
}

Future<void> _receiveInOrder(Validator validator, List<Record> records) async {
  for (final record in records) {
    expect(
      await validator.receiveText(canonicalJson(record.toJson())),
      ReceiveOutcome.accepted,
      reason: record.id,
    );
  }
}

/// The investor proposes a budget, and the manager approves it.
Future<(Record, Record)> _approvedBudget(
  ChainAuthor investor,
  ChainAuthor manager,
  String partnershipId,
  int amount,
) async {
  final budget = await investor.next(
    partnership: partnershipId,
    type: 'budget_proposal',
    body: {'grantee': manager.key, 'amount': amount},
  );
  final approve = await manager.next(
    partnership: partnershipId,
    type: 'approve',
    refersTo: budget.id,
  );
  return (budget, approve);
}

void main() {
  group('money totals (spec section 6.5)', () {
    test(
      'a full example gives the right capital, cash, result and profit paid',
      () async {
        final (validator, investor, manager, partnershipId) =
            await setUpPartnership();
        final invest = await investor.next(
          partnership: partnershipId,
          type: 'invest',
          body: {'amount': 10000},
        );
        final (budget, approveBudget) = await _approvedBudget(
          investor,
          manager,
          partnershipId,
          5000,
        );
        final sale = await manager.next(
          partnership: partnershipId,
          type: 'sale',
          body: {'amount': 4000},
        );
        final expense = await manager.next(
          partnership: partnershipId,
          type: 'expense',
          body: {'amount': 3000, 'receiptHash': null},
          refersTo: budget.id,
        );
        final withdrawCapital = await investor.next(
          partnership: partnershipId,
          type: 'withdraw_request',
          body: {'amount': 2000, 'kind': 'capital'},
        );
        final approveCapital = await manager.next(
          partnership: partnershipId,
          type: 'approve',
          refersTo: withdrawCapital.id,
        );
        final withdrawProfit = await investor.next(
          partnership: partnershipId,
          type: 'withdraw_request',
          body: {'amount': 500, 'kind': 'profit'},
        );
        final approveProfit = await manager.next(
          partnership: partnershipId,
          type: 'approve',
          refersTo: withdrawProfit.id,
        );
        await _receiveInOrder(validator, [
          invest,
          budget,
          approveBudget,
          sale,
          expense,
          withdrawCapital,
          approveCapital,
          withdrawProfit,
          approveProfit,
        ]);

        final money = await _money(validator);

        expect(money.capital, 8000); // 10000 invested - 2000 capital withdrawn
        expect(money.cashBalance, 8500); // 10000 + 4000 - 3000 - 2000 - 500
        expect(money.result, 1000); // 4000 sales - 3000 expenses
        expect(money.profitPaid, 500);
        expect(money.budgetLeft, {budget.id: 2000});
      },
    );

    test('an unapproved withdraw is not counted', () async {
      final (validator, investor, manager, partnershipId) =
          await setUpPartnership();
      final invest = await investor.next(
        partnership: partnershipId,
        type: 'invest',
        body: {'amount': 10000},
      );
      final withdraw = await investor.next(
        partnership: partnershipId,
        type: 'withdraw_request',
        body: {'amount': 700, 'kind': 'profit'},
      );
      await _receiveInOrder(validator, [invest, withdraw]);

      final money = await _money(validator);

      expect(money.profitPaid, 0);
      expect(money.cashBalance, 10000);
    });

    test('a reversed sale is not counted', () async {
      final (validator, investor, manager, partnershipId) =
          await setUpPartnership();
      final invest = await investor.next(
        partnership: partnershipId,
        type: 'invest',
        body: {'amount': 10000},
      );
      final sale = await manager.next(
        partnership: partnershipId,
        type: 'sale',
        body: {'amount': 4000},
      );
      final reversal = await manager.next(
        partnership: partnershipId,
        type: 'reversal',
        refersTo: sale.id,
      );
      await _receiveInOrder(validator, [invest, sale, reversal]);

      final money = await _money(validator);

      expect(money.result, 0);
      expect(money.cashBalance, 10000);
    });

    test('an over-budget expense is not counted in result or cash', () async {
      final (validator, investor, manager, partnershipId) =
          await setUpPartnership();
      final (budget, approve) = await _approvedBudget(
        investor,
        manager,
        partnershipId,
        2000,
      );
      final expense = await manager.next(
        partnership: partnershipId,
        type: 'expense',
        body: {'amount': 3000, 'receiptHash': null},
        refersTo: budget.id,
      );
      await _receiveInOrder(validator, [budget, approve, expense]);

      final money = await _money(validator);

      expect(money.result, 0);
      expect(money.budgetLeft, {budget.id: 2000});
    });

    test(
      "a reversal of an expense gives its budget back from its position",
      () async {
        final (validator, investor, manager, partnershipId) =
            await setUpPartnership();
        final (budget, approve) = await _approvedBudget(
          investor,
          manager,
          partnershipId,
          5000,
        );
        final expense = await manager.next(
          partnership: partnershipId,
          type: 'expense',
          body: {'amount': 3000, 'receiptHash': null},
          refersTo: budget.id,
        );
        final reversal = await manager.next(
          partnership: partnershipId,
          type: 'reversal',
          refersTo: expense.id,
        );
        await _receiveInOrder(validator, [budget, approve, expense, reversal]);

        final money = await _money(validator);

        expect(money.budgetLeft, {budget.id: 5000});
        expect(money.result, 0);
      },
    );

    test(
      'an invest with a zero amount is rejected, not stored',
      () async {
        // Spec section 5's schema step now catches this directly: an
        // invest needs a positive amount to be accepted at all, so it
        // never reaches `computeMoney` to be type-checked there.
        final (validator, investor, _, partnershipId) =
            await setUpPartnership();
        final bad = await investor.next(
          partnership: partnershipId,
          type: 'invest',
          body: {'amount': 0},
        );

        expect(
          await validator.receiveText(canonicalJson(bad.toJson())),
          ReceiveOutcome.rejectedSchema,
        );

        final money = await _money(validator);

        expect(money.capital, 0);
        expect(money.cashBalance, 0);
      },
    );

    test('a withdraw of an unknown kind is rejected, not stored', () async {
      // Spec section 5's schema step now requires `kind` to be exactly
      // "capital" or "profit", so this never reaches `computeMoney` either.
      final (validator, investor, manager, partnershipId) =
          await setUpPartnership();
      final invest = await investor.next(
        partnership: partnershipId,
        type: 'invest',
        body: {'amount': 1000},
      );
      final withdraw = await investor.next(
        partnership: partnershipId,
        type: 'withdraw_request',
        body: {'amount': 400, 'kind': 'bonus'},
      );
      await _receiveInOrder(validator, [invest]);

      expect(
        await validator.receiveText(canonicalJson(withdraw.toJson())),
        ReceiveOutcome.rejectedSchema,
      );

      final money = await _money(validator);

      expect(money.profitPaid, 0);
      expect(money.capital, 1000);
      expect(money.cashBalance, 1000);
    });
  });

  group('profit split (spec section 6.5)', () {
    test('a profit is shared by the percentages', () {
      final shares = splitResult(1000, investorPercent: 60, managerPercent: 40);

      expect(shares.manager, 400);
      expect(shares.investor, 600);
    });

    test('the remainder from integer division goes to the investor', () {
      final shares = splitResult(1001, investorPercent: 60, managerPercent: 40);

      // 1001 * 40 / 100 = 400.4, so the manager gets 400 and the investor 601.
      expect(shares.manager, 400);
      expect(shares.investor, 601);
    });

    test('a share smaller than one paisa goes to the investor', () {
      final shares = splitResult(1, investorPercent: 60, managerPercent: 40);

      expect(shares.manager, 0);
      expect(shares.investor, 1);
    });

    test(
      'a loss is carried by the investor, and the manager share is zero',
      () {
        final shares = splitResult(
          -500,
          investorPercent: 60,
          managerPercent: 40,
        );

        expect(shares.investor, -500);
        expect(shares.manager, 0);
      },
    );

    test('a zero result gives zero to both partners', () {
      final shares = splitResult(0, investorPercent: 60, managerPercent: 40);

      expect(shares.investor, 0);
      expect(shares.manager, 0);
    });

    test('a ratio that does not add up to 100 is rejected', () {
      expect(
        () => splitResult(1000, investorPercent: 60, managerPercent: 30),
        throwsArgumentError,
      );
      expect(
        () => splitResult(1000, investorPercent: 110, managerPercent: -10),
        throwsArgumentError,
      );
    });

    test(
      'shares always add up to the result, for 1,000 random cases (fixed seed)',
      () {
        final random = Random(1234);
        for (var i = 0; i < 1000; i++) {
          final result = random.nextInt(2000001) - 1000000;
          final managerPercent = random.nextInt(101);
          final shares = splitResult(
            result,
            investorPercent: 100 - managerPercent,
            managerPercent: managerPercent,
          );

          expect(shares.investor + shares.manager, result, reason: 'case $i');
          if (result > 0) {
            // The manager gets the largest whole paisa amount not above their share.
            expect(
              shares.manager * 100 <= result * managerPercent,
              isTrue,
              reason: 'case $i',
            );
            expect(
              (shares.manager + 1) * 100 > result * managerPercent,
              isTrue,
              reason: 'case $i',
            );
          }
        }
      },
    );
  });

  group('order independence (spec section 6.5, hard rule 5)', () {
    test(
      'the same records in different arrival orders give the same totals',
      () async {
        final (first, investor, manager, partnershipId) =
            await setUpPartnership();
        final create = first.usableRecords.singleWhere(
          (r) => r.type == 'partnership_create',
        );
        final invest = await investor.next(
          partnership: partnershipId,
          type: 'invest',
          body: {'amount': 10000},
        );
        final (budget, approveBudget) = await _approvedBudget(
          investor,
          manager,
          partnershipId,
          5000,
        );
        final sale = await manager.next(
          partnership: partnershipId,
          type: 'sale',
          body: {'amount': 4000},
        );
        final expense = await manager.next(
          partnership: partnershipId,
          type: 'expense',
          body: {'amount': 3000, 'receiptHash': null},
          refersTo: budget.id,
        );
        final orders = [
          [invest, budget, approveBudget, sale, expense],
          [expense, sale, approveBudget, budget, invest],
          [sale, invest, expense, approveBudget, budget],
        ];

        MoneySummary? baseline;
        for (final order in orders) {
          final validator = Validator.unpinnedForTesting();
          await validator.receiveText(canonicalJson(create.toJson()));
          for (final record in order) {
            await validator.receiveText(canonicalJson(record.toJson()));
          }
          final money = await _money(validator);

          baseline ??= money;
          expect(money.capital, baseline.capital);
          expect(money.cashBalance, baseline.cashBalance);
          expect(money.result, baseline.result);
          expect(money.budgetLeft, equals(baseline.budgetLeft));
        }
        expect(baseline!.result, 1000);
      },
    );
  });
}
