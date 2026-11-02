import 'amounts.dart';
import 'authorization.dart';
import 'budget_view.dart';
import 'effective.dart';
import 'money.dart';
import 'periods.dart';
import 'record.dart';
import 'settlement.dart';
import 'validator.dart';

/// Every type whose body carries `amount`, and so is schema-rejected by
/// [Validator] on receipt (`validator.dart`) when it is not a positive
/// integer. Checked once, before the switch below, so none of these five
/// cases has to repeat the check.
const _amountTypes = {
  'invest',
  'sale',
  'budget_proposal',
  'expense',
  'withdraw_request',
};

/// Why a proposal would be refused before it is even built (spec sections 5,
/// 6.4, 6.7).
///
/// `RecordWriter` (apps/mobile) and the evaluation workload generator both
/// call [proposalRefusal], so the rule is decided in one place: the
/// generator must skip exactly the intents the app itself would never write.
enum ProposalRefusal {
  /// [proposalRefusal]'s `author` is not the role spec section 5 allows for
  /// its `type` (and a capital `withdraw_request` is investor-only).
  wrongRole,

  /// An `invest`, `sale`, `budget_proposal`, `expense` or `withdraw_request`
  /// was proposed with an `amount` that is not a positive integer. Every one
  /// of these types is schema-rejected by [Validator] on receipt when its
  /// amount is not positive (hard rule 1), so writing one here would only
  /// ever produce a record every other device throws away.
  nonPositiveAmount,

  /// An `expense`'s budget is not one that is both approved and granted to
  /// the author (spec section 5, 6.4).
  noEffectiveBudget,

  /// An `expense`'s amount is more than that budget has left right now
  /// (decision 2026-10-11).
  overBudget,

  /// A capital `withdraw_request`'s amount is more than the current capital
  /// (decision 2026-10-16). Does not apply to a profit withdrawal.
  overCapital,

  /// A `reversal`'s target is not one of the types spec section 5 allows to
  /// be reversed, or is not held on this phone at all.
  notReversible,

  /// A `settlement`'s cut, beyond the last effective settlement's, covers
  /// nothing but settlement bookkeeping (spec 6.7, cut rule 5).
  emptyCut,
}

/// The result of [proposalRefusal]: the reason, and (for
/// [ProposalRefusal.overBudget] or [ProposalRefusal.overCapital]) the amount
/// actually left, so a caller can report it without recomputing it.
class ProposalRefusalResult {
  const ProposalRefusalResult(this.reason, {this.budgetLeft, this.capitalLeft});

  final ProposalRefusal reason;

  /// Set only for [ProposalRefusal.overBudget].
  final int? budgetLeft;

  /// Set only for [ProposalRefusal.overCapital].
  final int? capitalLeft;
}

/// Why proposing a [type] record authored by [author] would be refused, or
/// `null` when it is allowed.
///
/// [ledger] is every record this phone has stored, not only the usable
/// ones — a reversal target that is chain-invalid or equivocating is still
/// "held," so it is still reversible (spec section 5 names the type, not the
/// status). [validator] is read for the partnership's usable records and
/// keys, which the budget and settlement checks need. Call this only once
/// the partnership is already active; it does not check that itself.
///
/// Extra parameters, by [type]:
/// - `invest`, `sale`, `budget_proposal`: pass [amount], checked only for
///   being positive.
/// - `withdraw_request`: pass [kind] (`"capital"` or `"profit"`) and
///   [amount] (checked for being positive, then against current capital,
///   but only when [kind] is `"capital"`; a profit withdrawal is not
///   checked against capital here).
/// - `expense`: pass [budgetId] (the chosen budget's id) and [amount]
///   (checked for being positive, then against the budget's remaining
///   amount).
/// - `reversal`: pass [reversalTarget] (the id of the record to reverse).
/// - every other type (`ratio_proposal`, `settlement`): no extra parameter
///   is read.
ProposalRefusalResult? proposalRefusal({
  required String type,
  required String author,
  required Parties parties,
  required List<Record> ledger,
  required Validator validator,
  String? kind,
  String? budgetId,
  int? amount,
  String? reversalTarget,
}) {
  if (!canAuthor(type, author, parties, kind: kind)) {
    return const ProposalRefusalResult(ProposalRefusal.wrongRole);
  }
  if (_amountTypes.contains(type) && !isPositiveAmount(amount)) {
    return const ProposalRefusalResult(ProposalRefusal.nonPositiveAmount);
  }

  final keys = validator.partnershipKeys ?? const <String>{};

  switch (type) {
    case 'withdraw_request':
      if (kind != 'capital') return null;
      final effectiveness = computeEffective(
        validator.usableRecords,
        partnershipKeys: keys,
      );
      final capital = computeMoney(
        validator.usableRecords,
        effectiveness: effectiveness,
      ).capital;
      if (amount != null && amount > capital) {
        return ProposalRefusalResult(
          ProposalRefusal.overCapital,
          capitalLeft: capital,
        );
      }
      return null;

    case 'expense':
      final budgets = effectiveBudgetsFor(
        validator.usableRecords,
        partnershipKeys: keys,
        grantee: author,
      );
      final left = budgets[budgetId];
      if (left == null) {
        return const ProposalRefusalResult(ProposalRefusal.noEffectiveBudget);
      }
      if (amount != null && amount > left) {
        return ProposalRefusalResult(
          ProposalRefusal.overBudget,
          budgetLeft: left,
        );
      }
      return null;

    case 'reversal':
      const reversible = {'invest', 'sale', 'expense', 'withdraw_request'};
      final target = ledger.where((r) => r.id == reversalTarget);
      if (target.isEmpty || !reversible.contains(target.single.type)) {
        return const ProposalRefusalResult(ProposalRefusal.notReversible);
      }
      return null;

    case 'settlement':
      final shares = periodShares(validator.usableRecords, partnershipKeys: keys);
      final candidate = shares.last.closingCut;
      final previous = shares.length >= 2
          ? shares[shares.length - 2].closingCut
          : {parties.investor: 0, parties.manager: 0};
      final coversNew = coversNewBusiness(
        previous,
        candidate,
        validator.usableRecords,
      );
      return coversNew
          ? null
          : const ProposalRefusalResult(ProposalRefusal.emptyCut);

    default:
      return null;
  }
}
