import 'active_ratio.dart';
import 'effective.dart';
import 'money.dart';
import 'ratio.dart';
import 'record.dart';

/// Every number the dashboard shows, spec sections 6.5 and 6.6.
///
/// Nothing here is stored. The screen asks for a new [Dashboard] from the
/// usable records each time, so a reversal or a late record is always counted
/// (hard rule 4: store facts, calculate everything else).
class Dashboard {
  final MoneySummary money;

  /// The split that applies on the chosen date, or `null` if no partnership
  /// is effective yet.
  final Ratio? ratio;

  /// The partners' shares of the result, or `null` when [ratio] is `null`.
  final ProfitShares? shares;

  const Dashboard({
    required this.money,
    required this.ratio,
    required this.shares,
  });
}

/// Calculates the dashboard from [usable] records, spec 6.5 and 6.6.
///
/// [usable] must already be filtered by `Validator.usableRecords`.
/// [date] is the `YYYY-MM-DD` day whose ratio is shown. The app passes today's
/// date. Spec 6.6 says v1 splits the whole result with that one ratio, so a
/// ratio change mid-period is not split per period yet (future work).
Dashboard buildDashboard(
  Iterable<Record> usable, {
  required Set<String> partnershipKeys,
  required String date,
}) {
  final records = usable.toList();
  final effectiveness = computeEffective(
    records,
    partnershipKeys: partnershipKeys,
  );
  final money = computeMoney(records, effectiveness: effectiveness);
  final ratio = activeRatio(records, effectiveness: effectiveness, date: date);
  final shares = ratio == null
      ? null
      : splitResult(
          money.result,
          investorPercent: ratio.investor,
          managerPercent: ratio.manager,
        );
  return Dashboard(money: money, ratio: ratio, shares: shares);
}
