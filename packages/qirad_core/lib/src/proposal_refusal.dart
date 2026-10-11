import 'authorization.dart';
import 'budget_view.dart';
import 'periods.dart';
import 'record.dart';
import 'settlement.dart';
import 'validator.dart';

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

  /// An `expense`'s budget is not one that is both approved and granted to
  /// the author (spec section 5, 6.4).
  noEffectiveBudget,

  /// An `expense`'s amount is more than that budget has left right now
  /// (decision 2026-10-11).
  overBudget,

  /// A `reversal`'s target is not one of the types spec section 5 allows to
  /// be reversed, or is not held on this phone at all.
  notReversible,

  /// A `settlement`'s cut, beyond the last effective settlement's, covers
  /// nothing but settlement bookkeeping (spec 6.7, cut rule 5).
  emptyCut,
}

/// The result of [proposalRefusal]: the reason, and (for
/// [ProposalRefusal.overBudget] only) the amount actually left, so a caller
/// can report it without recomputing it.
class ProposalRefusalResult {
  const ProposalRefusalResult(this.reason, {this.budgetLeft});

  final ProposalRefusal reason;

  /// Set only for [ProposalRefusal.overBudget].
  final int? budgetLeft;
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
/// - `withdraw_request`: pass [kind] (`"capital"` or `"profit"`).
/// - `expense`: pass [budgetId] (the chosen budget's id) and [amount].
/// - `reversal`: pass [reversalTarget] (the id of the record to reverse).
/// - every other type (`invest`, `sale`, `budget_proposal`, `ratio_proposal`,
///   `settlement`): no extra parameter is read.
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

  final keys = validator.partnershipKeys ?? const <String>{};

  switch (type) {
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
