import 'active_ratio.dart';
import 'amounts.dart';
import 'effective.dart';
import 'money.dart';
import 'periods.dart';
import 'ratio.dart';
import 'record.dart';
import 'settlement.dart';

/// What the investor sees before answering a settlement (spec 6.7).
///
/// Every value is copied from [periodShares], the same function that reports
/// the settled period once the settlement is effective. The summary does no
/// arithmetic of its own, so it cannot disagree with the ledger.
class SettlementConsent {
  const SettlementConsent({
    required this.periodIndex,
    required this.result,
    required this.shares,
    required this.ratio,
    required this.previousRatio,
  });

  /// 1 for the first period, as in [PeriodShares.index].
  final int periodIndex;

  /// The period's own result, in paisa (spec 6.7).
  final int result;

  /// Each partner's share of [result], after loss carry-forward.
  final ProfitShares shares;

  /// The ratio this period is split at.
  final Ratio ratio;

  /// The ratio of the period before, or null for the first period.
  final Ratio? previousRatio;

  /// True when this period splits profit differently from the one before it.
  /// The screen shows a warning, so the investor sees the change.
  bool get ratioChanged => previousRatio != null && previousRatio != ratio;

  /// Equal when every number the investor was shown is equal. The writer uses
  /// this to check that the summary has not changed since it was shown.
  @override
  bool operator ==(Object other) =>
      other is SettlementConsent &&
      other.periodIndex == periodIndex &&
      other.result == result &&
      other.shares.investor == shares.investor &&
      other.shares.manager == shares.manager &&
      other.ratio == ratio &&
      other.previousRatio == previousRatio;

  @override
  int get hashCode => Object.hash(
    periodIndex,
    result,
    shares.investor,
    shares.manager,
    ratio,
    previousRatio,
  );
}

/// What the investor sees before answering a withdrawal (spec 6.7).
///
/// Every value comes from [totalProfitWithdrawn], [withdrawalSplits] or
/// [periodShares], the same functions the dashboard uses.
class WithdrawalConsent {
  const WithdrawalConsent({
    required this.amount,
    required this.kind,
    required this.settledShare,
    required this.totalProfitWithdrawn,
    required this.aheadOfSettled,
    required this.owedBack,
  });

  /// The amount asked for, in paisa.
  final int amount;

  /// `capital` or `profit`.
  final String kind;

  /// The requester's settled profit so far: shares plus corrections of every
  /// closed period.
  final int settledShare;

  /// The requester's profit withdrawn in total, after this withdrawal.
  final int totalProfitWithdrawn;

  /// Withdrawn ahead of settled profit. Neutral, not a debt.
  final int aheadOfSettled;

  /// Owed back, caused by a correction that reduced a settled share.
  final int owedBack;

  /// True when some money is owed back. The screen shows a warning.
  bool get hasOwedBack => owedBack > 0;

  /// Equal when every number the investor was shown is equal (see
  /// [SettlementConsent]).
  @override
  bool operator ==(Object other) =>
      other is WithdrawalConsent &&
      other.amount == amount &&
      other.kind == kind &&
      other.settledShare == settledShare &&
      other.totalProfitWithdrawn == totalProfitWithdrawn &&
      other.aheadOfSettled == aheadOfSettled &&
      other.owedBack == owedBack;

  @override
  int get hashCode => Object.hash(
    amount,
    kind,
    settledShare,
    totalProfitWithdrawn,
    aheadOfSettled,
    owedBack,
  );
}

/// The consent summary for settlement [proposal], as core reports it once
/// [answer] makes the proposal effective.
///
/// [answer] may be a record that is not saved yet. It is only passed in as
/// input. If the answer does not make the settlement effective, there is no
/// period to report, so the result is null, and the screen shows no Approve
/// button.
SettlementConsent? settlementConsent(
  Iterable<Record> usable, {
  required Set<String> partnershipKeys,
  required Record proposal,
  required Record answer,
}) {
  final records = [...usable, answer];
  final parties = partiesOf(records);
  if (parties == null) return null;
  final cut = settlementCut(proposal, parties);
  if (cut == null) return null;

  final periods = periodShares(records, partnershipKeys: partnershipKeys);
  for (var i = 0; i < periods.length; i++) {
    final period = periods[i];
    if (period.open || !_sameCut(period.closingCut, cut)) continue;
    return SettlementConsent(
      periodIndex: period.index,
      result: period.result,
      shares: period.shares,
      ratio: period.ratio,
      previousRatio: i == 0 ? null : periods[i - 1].ratio,
    );
  }
  return null;
}

/// The consent summary for withdrawal [request], as core reports it once
/// [answer] makes the request effective. Null when it would not be effective.
WithdrawalConsent? withdrawalConsent(
  Iterable<Record> usable, {
  required Set<String> partnershipKeys,
  required Record request,
  required Record answer,
}) {
  final records = [...usable, answer];
  final effectiveness = computeEffective(
    records,
    partnershipKeys: partnershipKeys,
  );
  if (!effectiveness.isEffective(request)) return null;

  final amount = positiveAmount(request);
  final kind = request.body['kind'];
  if (amount == null || kind is! String) return null;

  final parties = partiesOf(records);
  if (parties == null) return null;
  final partner = request.author;
  final isInvestor = partner == parties.investor;

  // Settled share: each closed period's share plus the corrections booked in it.
  final settledShare = periodShares(records, partnershipKeys: partnershipKeys)
      .where((period) => !period.open)
      .fold<int>(0, (sum, period) {
        final shares = isInvestor
            ? period.shares.investor
            : period.shares.manager;
        final correction = isInvestor
            ? period.correction.investor
            : period.correction.manager;
        return sum + shares + correction;
      });

  final total = totalProfitWithdrawn(
    records,
    partnershipKeys: partnershipKeys,
  )[partner];
  final split = withdrawalSplits(
    records,
    partnershipKeys: partnershipKeys,
  )[partner];
  if (total == null || split == null) return null;

  return WithdrawalConsent(
    amount: amount,
    kind: kind,
    settledShare: settledShare,
    totalProfitWithdrawn: total,
    aheadOfSettled: split.aheadOfSettled,
    owedBack: split.owedBack,
  );
}

/// What the other partner sees before answering a `reversal` of their own
/// record (spec section 5; spec 6.7 "Prior-period adjustments" for the
/// closed-period case).
///
/// Every value is a difference the core calculations already report, read
/// once with the reversal not yet effective and once with [answer] making it
/// effective, so this cannot disagree with the dashboard or the settlement
/// screens. Which fields apply depends on [targetType] (spec 6.5): an
/// `invest` or `withdraw_request` only ever moves capital and cash; a `sale`
/// or `expense` only ever moves cash and a period's result.
class ReversalConsent {
  const ReversalConsent({
    required this.targetType,
    required this.targetAmount,
    required this.capitalChange,
    required this.cashChange,
    required this.periodIndex,
    required this.periodOpen,
    required this.resultChange,
    required this.shareCorrection,
    required this.deficitCorrectionChange,
    required this.freedBudgetId,
    required this.freedBudgetAmount,
  });

  /// `invest`, `sale`, `expense` or `withdraw_request` — the only types a
  /// reversal may target (spec section 5).
  final String targetType;
  final int targetAmount;

  /// Change in `capital`, `after - before`. Zero for `sale` and `expense`.
  final int capitalChange;

  /// Change in `cashBalance`, `after - before`. Every reversible type moves
  /// cash, so this is never zero.
  final int cashChange;

  /// The period that holds the target record. Null for `invest` and
  /// `withdraw_request`, which are never part of a period's result.
  final int? periodIndex;

  /// True while that period is still open. Null along with [periodIndex].
  final bool? periodOpen;

  /// Change in that period's own result, `after - before`. Set only when
  /// [periodOpen] is true (spec 6.7: "the change to the provisional result").
  final int? resultChange;

  /// Change in that period's booked correction, `after - before`, split
  /// between the partners. Set only when [periodOpen] is false (spec 6.7,
  /// "Prior-period adjustments": the share change booked where the reversal
  /// becomes effective).
  final ProfitShares? shareCorrection;

  /// Change in that period's booked deficit change, `after - before`. Set
  /// together with [shareCorrection].
  final int? deficitCorrectionChange;

  /// The `budget_proposal` id this expense drew from, and how much its
  /// `budgetLeft` grows by once the reversal is effective. Both null unless
  /// [targetType] is `expense`.
  final String? freedBudgetId;
  final int? freedBudgetAmount;

  /// Equal when every number the partner was shown is equal (see
  /// [SettlementConsent]).
  @override
  bool operator ==(Object other) =>
      other is ReversalConsent &&
      other.targetType == targetType &&
      other.targetAmount == targetAmount &&
      other.capitalChange == capitalChange &&
      other.cashChange == cashChange &&
      other.periodIndex == periodIndex &&
      other.periodOpen == periodOpen &&
      other.resultChange == resultChange &&
      other.shareCorrection?.investor == shareCorrection?.investor &&
      other.shareCorrection?.manager == shareCorrection?.manager &&
      other.deficitCorrectionChange == deficitCorrectionChange &&
      other.freedBudgetId == freedBudgetId &&
      other.freedBudgetAmount == freedBudgetAmount;

  @override
  int get hashCode => Object.hash(
    targetType,
    targetAmount,
    capitalChange,
    cashChange,
    periodIndex,
    periodOpen,
    resultChange,
    shareCorrection?.investor,
    shareCorrection?.manager,
    deficitCorrectionChange,
    freedBudgetId,
    freedBudgetAmount,
  );
}

/// The consent summary for a `reversal` of [reversal]'s target, as core
/// reports it once [answer] makes the reversal effective. Null when the
/// target would not actually become cancelled — including when the target is
/// not a reversible type (spec section 5), which the validator lets through
/// unflagged until this point, and when the target was never effective to
/// begin with.
ReversalConsent? reversalConsent(
  Iterable<Record> usable, {
  required Set<String> partnershipKeys,
  required Record reversal,
  required Record answer,
}) {
  final before = usable.toList();
  final target = before.where((r) => r.id == reversal.refersTo);
  if (target.isEmpty) return null;
  final targetRecord = target.single;

  final beforeEffectiveness = computeEffective(
    before,
    partnershipKeys: partnershipKeys,
  );
  if (!beforeEffectiveness.isEffective(targetRecord)) return null;

  final after = [...before, answer];
  final afterEffectiveness = computeEffective(
    after,
    partnershipKeys: partnershipKeys,
  );
  if (afterEffectiveness.isEffective(targetRecord)) return null;

  final beforeMoney = computeMoney(before, effectiveness: beforeEffectiveness);
  final afterMoney = computeMoney(after, effectiveness: afterEffectiveness);
  final amount = positiveAmount(targetRecord) ?? 0;

  int? periodIndex;
  bool? periodOpen;
  int? resultChange;
  ProfitShares? shareCorrection;
  int? deficitCorrectionChange;
  String? freedBudgetId;
  int? freedBudgetAmount;

  if (targetRecord.type == 'sale' || targetRecord.type == 'expense') {
    // The record's own period: cuts only grow (rule 4), so the first closing
    // cut that reaches this author's seq is the period that holds it.
    final beforePeriods = periodShares(before, partnershipKeys: partnershipKeys);
    PeriodShares? home;
    for (final period in beforePeriods) {
      final bound = period.closingCut[targetRecord.author];
      if (bound != null && targetRecord.seq <= bound) {
        home = period;
        break;
      }
    }

    if (home != null) {
      periodIndex = home.index;
      periodOpen = home.open;
      final afterPeriods = periodShares(after, partnershipKeys: partnershipKeys);

      if (home.open) {
        // Nothing has closed around this record yet: the reversal changes
        // that same open period's own result directly (spec 6.7, "the
        // change to the provisional result").
        final afterHome = afterPeriods.firstWhere((p) => p.index == home!.index);
        resultChange = afterHome.result - home.result;
      } else {
        // The record's period is already closed: the difference is booked as
        // a correction wherever the reversal and its approval actually land,
        // which may be a later period (spec 6.7, "Prior-period adjustments").
        for (var i = 0; i < beforePeriods.length && i < afterPeriods.length; i++) {
          final b = beforePeriods[i];
          final a = afterPeriods[i];
          final changed =
              b.correction.investor != a.correction.investor ||
              b.correction.manager != a.correction.manager ||
              b.deficitChange != a.deficitChange;
          if (!changed) continue;
          shareCorrection = ProfitShares(
            investor: a.correction.investor - b.correction.investor,
            manager: a.correction.manager - b.correction.manager,
          );
          deficitCorrectionChange = a.deficitChange - b.deficitChange;
          break;
        }
      }
    }

    if (targetRecord.type == 'expense') {
      final budgetId = targetRecord.refersTo;
      final beforeLeft = budgetId == null ? null : beforeMoney.budgetLeft[budgetId];
      final afterLeft = budgetId == null ? null : afterMoney.budgetLeft[budgetId];
      if (budgetId != null && beforeLeft != null && afterLeft != null) {
        freedBudgetId = budgetId;
        freedBudgetAmount = afterLeft - beforeLeft;
      }
    }
  }

  return ReversalConsent(
    targetType: targetRecord.type,
    targetAmount: amount,
    capitalChange: afterMoney.capital - beforeMoney.capital,
    cashChange: afterMoney.cashBalance - beforeMoney.cashBalance,
    periodIndex: periodIndex,
    periodOpen: periodOpen,
    resultChange: resultChange,
    shareCorrection: shareCorrection,
    deficitCorrectionChange: deficitCorrectionChange,
    freedBudgetId: freedBudgetId,
    freedBudgetAmount: freedBudgetAmount,
  );
}

/// What the other partner sees before answering a `budget_proposal` (spec
/// section 5; spec 6.4/6.5 for the cash figures).
///
/// [cashBalance] and [openBudgets] are read from [computeMoney] on the
/// records as they stand now, the same totals the dashboard shows — the
/// proposal itself is not counted yet, since it only becomes a budget once
/// approved. [overCommitted] warns when approving would let the open budgets
/// exceed the cash actually available.
class BudgetConsent {
  const BudgetConsent({
    required this.grantee,
    required this.amount,
    required this.cashBalance,
    required this.openBudgets,
  });

  final String grantee;
  final int amount;
  final int cashBalance;

  /// Sum of `budgetLeft` over every other effective budget (spec 6.4), not
  /// counting this proposal.
  final int openBudgets;

  /// True when approving would let open budgets exceed available cash.
  bool get overCommitted => cashBalance < openBudgets + amount;

  /// Equal when every number the partner was shown is equal (see
  /// [SettlementConsent]).
  @override
  bool operator ==(Object other) =>
      other is BudgetConsent &&
      other.grantee == grantee &&
      other.amount == amount &&
      other.cashBalance == cashBalance &&
      other.openBudgets == openBudgets;

  @override
  int get hashCode => Object.hash(grantee, amount, cashBalance, openBudgets);
}

/// The consent summary for a `budget_proposal` [proposal], as core reports it
/// right now. Null when the proposal's own body is malformed (the schema
/// step should already have refused it, so this is defensive, decision Q3b's
/// "handed bad input on purpose" style).
BudgetConsent? budgetConsent(
  Iterable<Record> usable, {
  required Set<String> partnershipKeys,
  required Record proposal,
}) {
  final grantee = proposal.body['grantee'];
  final amount = positiveAmount(proposal);
  if (grantee is! String || amount == null) return null;

  final records = usable.toList();
  final effectiveness = computeEffective(
    records,
    partnershipKeys: partnershipKeys,
  );
  final money = computeMoney(records, effectiveness: effectiveness);
  final openBudgets = money.budgetLeft.values.fold<int>(
    0,
    (sum, left) => sum + left,
  );

  return BudgetConsent(
    grantee: grantee,
    amount: amount,
    cashBalance: money.cashBalance,
    openBudgets: openBudgets,
  );
}

/// What the other partner sees before answering a `ratio_proposal` (spec
/// 6.6). [currentRatio] is the ratio in force right now, before this
/// proposal is answered — calculated, so it can move if a different ratio
/// change becomes effective in between, which is exactly what the writer's
/// optimistic check guards against. [proposedRatio] and [effectiveFrom] are
/// the proposal's own fixed body.
class RatioConsent {
  const RatioConsent({
    required this.currentRatio,
    required this.proposedRatio,
    required this.effectiveFrom,
  });

  final Ratio currentRatio;
  final Ratio proposedRatio;

  /// `YYYY-MM-DD`, shown as plain text. Nothing is calculated from it here
  /// (hard rule 3); it only takes effect after the next settlement (spec 6.6).
  final String effectiveFrom;

  /// Equal when every value the partner was shown is equal (see
  /// [SettlementConsent]).
  @override
  bool operator ==(Object other) =>
      other is RatioConsent &&
      other.currentRatio == currentRatio &&
      other.proposedRatio == proposedRatio &&
      other.effectiveFrom == effectiveFrom;

  @override
  int get hashCode =>
      Object.hash(currentRatio, proposedRatio, effectiveFrom);
}

/// The consent summary for a `ratio_proposal` [proposal], as core reports it
/// right now. Null when the proposal's own body is malformed, or when there
/// is no active ratio yet to compare against (defensive, same as
/// [budgetConsent]).
RatioConsent? ratioConsent(
  Iterable<Record> usable, {
  required Set<String> partnershipKeys,
  required Record proposal,
}) {
  final proposedRatio = ratioOf(proposal);
  final effectiveFrom = proposal.body['effectiveFrom'];
  if (proposedRatio == null ||
      effectiveFrom is! String ||
      !isIsoDate(effectiveFrom)) {
    return null;
  }

  final records = usable.toList();
  final effectiveness = computeEffective(
    records,
    partnershipKeys: partnershipKeys,
  );
  final current = activeRatio(records, effectiveness: effectiveness);
  if (current == null) return null;

  return RatioConsent(
    currentRatio: current.ratio,
    proposedRatio: proposedRatio,
    effectiveFrom: effectiveFrom,
  );
}

bool _sameCut(Map<String, int> a, Map<String, int> b) {
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (b[entry.key] != entry.value) return false;
  }
  return true;
}
