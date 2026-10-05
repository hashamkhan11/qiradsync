import 'active_ratio.dart';
import 'effective.dart';
import 'money.dart';
import 'record.dart';

/// Every number the dashboard shows, spec sections 6.5 and 6.6.
///
/// Nothing here is stored, and no clock is used. The screen asks for a new
/// [Dashboard] from the usable records each time, so a reversal or a late
/// record is always counted (hard rule 4: store facts, calculate everything else).
class Dashboard {
  final MoneySummary money;

  /// The ratio in force, or `null` if the partnership is not approved yet.
  final ActiveRatio? ratio;

  /// The partners' shares of the result, or `null` when [ratio] is `null`.
  final ProfitShares? shares;

  /// True when an effective `ratio_proposal` exists. The shares then use the
  /// current ratio for all the result, which may not match the contract
  /// (docs/decisions.md, open issue: settlement).
  final bool ratioChanged;

  const Dashboard({
    required this.money,
    required this.ratio,
    required this.shares,
    required this.ratioChanged,
  });
}

/// Calculates the dashboard from [usable] records, spec 6.5 and 6.6.
///
/// [usable] must already be filtered by `Validator.usableRecords`.
Dashboard buildDashboard(
  Iterable<Record> usable, {
  required Set<String> partnershipKeys,
}) {
  final records = usable.toList();
  final effectiveness = computeEffective(
    records,
    partnershipKeys: partnershipKeys,
  );
  final money = computeMoney(records, effectiveness: effectiveness);
  final ratio = activeRatio(records, effectiveness: effectiveness);
  final shares = ratio == null
      ? null
      : splitResult(
          money.result,
          investorPercent: ratio.ratio.investor,
          managerPercent: ratio.ratio.manager,
        );
  final changed = records.any(
    (r) => r.type == 'ratio_proposal' && effectiveness.isEffective(r),
  );
  return Dashboard(
    money: money,
    ratio: ratio,
    shares: shares,
    ratioChanged: changed,
  );
}
