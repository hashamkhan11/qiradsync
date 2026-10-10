import 'effective.dart';
import 'money.dart';
import 'record.dart';

/// The records that fall inside [cut] (spec 6.7): for each partner, every
/// record up to that partner's value in the cut.
///
/// The `partnership_create` is always inside. It defines the partnership, so
/// no calculation can work without it.
List<Record> recordsInCut(Iterable<Record> usable, Map<String, int> cut) {
  return usable
      .where(
        (r) =>
            r.type == 'partnership_create' ||
            (cut[r.author] != null && r.seq <= cut[r.author]!),
      )
      .toList();
}

/// The money of the records inside [cut], calculated only from those records.
///
/// Spec 6.7 principle: a settled period is a pure function of its cut. A record
/// outside the cut cannot change this result, even if it arrives later. So a
/// late approval, or a late budget consent, never changes a settled view. Its
/// effect shows up in the period where it becomes visible (see [periodResult]).
MoneySummary cutMoney(
  Iterable<Record> usable, {
  required Set<String> partnershipKeys,
  required Map<String, int> cut,
}) {
  final inside = recordsInCut(usable, cut);
  final effectiveness = computeEffective(
    inside,
    partnershipKeys: partnershipKeys,
  );
  return computeMoney(inside, effectiveness: effectiveness);
}

/// The money that a period adds: the view at [to] minus the view at [from].
///
/// Each cut is a fixed set, so the difference is fixed too. A late effect, such
/// as an approval that falls after [from], is booked in the period where it
/// first appears in a view. Settled periods are never changed (spec 6.7).
MoneySummary periodMoney(
  Iterable<Record> usable, {
  required Set<String> partnershipKeys,
  required Map<String, int> from,
  required Map<String, int> to,
}) {
  final start = cutMoney(usable, partnershipKeys: partnershipKeys, cut: from);
  final end = cutMoney(usable, partnershipKeys: partnershipKeys, cut: to);
  return MoneySummary(
    capital: end.capital - start.capital,
    cashBalance: end.cashBalance - start.cashBalance,
    result: end.result - start.result,
    profitPaid: end.profitPaid - start.profitPaid,
    budgetLeft: end.budgetLeft,
  );
}
