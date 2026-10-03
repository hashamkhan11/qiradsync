import 'effective.dart';
import 'amounts.dart';
import 'record.dart';

/// The profit or loss from [splitResult], in paisa. Shares always add up to the
/// result exactly, so no paisa is lost or created.
class ProfitShares {
  final int investor;
  final int manager;

  const ProfitShares({required this.investor, required this.manager});
}

/// Money totals from the effective records, spec section 6.5. These are
/// calculated every time from the records, never stored.
class MoneySummary {
  final int capital;
  final int cashBalance;
  final int result;
  final int profitPaid;

  /// Budget id -> `B.amount - used(B)`, for every effective budget.
  final Map<String, int> budgetLeft;

  const MoneySummary({
    required this.capital,
    required this.cashBalance,
    required this.result,
    required this.profitPaid,
    required this.budgetLeft,
  });
}

/// Adds up the effective records, spec section 6.5. Only records that are
/// effective count. Everything is integer paisa (hard rule 1).
MoneySummary computeMoney(
  Iterable<Record> usable, {
  required Effectiveness effectiveness,
}) {
  var invested = 0;
  var sales = 0;
  var expenses = 0;
  var capitalWithdrawn = 0;
  var profitPaid = 0;
  final budgetAmount = <String, int>{};

  for (final record in usable) {
    if (!effectiveness.isEffective(record)) continue;

    final amount = positiveAmount(record);
    switch (record.type) {
      case 'invest':
        invested += amount!;
      case 'sale':
        sales += amount!;
      case 'expense':
        expenses += amount!;
      case 'withdraw_request':
        if (record.body['kind'] == 'capital') {
          capitalWithdrawn += amount!;
        } else {
          profitPaid += amount!;
        }
      case 'budget_proposal':
        budgetAmount[record.id] = amount!;
    }
  }

  final budgetLeft = {
    for (final entry in budgetAmount.entries)
      entry.key: entry.value - (effectiveness.budgetUsed[entry.key] ?? 0),
  };

  return MoneySummary(
    capital: invested - capitalWithdrawn,
    cashBalance: invested + sales - expenses - capitalWithdrawn - profitPaid,
    result: sales - expenses,
    profitPaid: profitPaid,
    budgetLeft: budgetLeft,
  );
}

/// Splits a [result] between the partners, spec section 6.5.
///
/// A profit is shared by the percentages. The manager's share is rounded down
/// with integer division, and the investor takes the rest. So any remainder
/// goes to the investor (decision 2026-10-03). A loss is carried entirely by
/// the investor, and the manager's share is 0.
ProfitShares splitResult(
  int result, {
  required int investorPercent,
  required int managerPercent,
}) {
  if (investorPercent < 0 ||
      managerPercent < 0 ||
      investorPercent + managerPercent != 100) {
    throw ArgumentError(
      'ratio must be two non-negative percentages summing to 100',
    );
  }

  if (result <= 0) {
    return ProfitShares(investor: result, manager: 0);
  }

  final manager = result * managerPercent ~/ 100;
  return ProfitShares(investor: result - manager, manager: manager);
}
