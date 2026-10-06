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

bool _sameCut(Map<String, int> a, Map<String, int> b) {
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (b[entry.key] != entry.value) return false;
  }
  return true;
}
