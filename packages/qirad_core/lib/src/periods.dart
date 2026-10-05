import 'dart:math' as math;

import 'active_ratio.dart';
import 'cut_view.dart';
import 'effective.dart';
import 'money.dart';
import 'ratio.dart';
import 'record.dart';
import 'settlement.dart';
import 'settlement_states.dart';

/// One period of the ledger, with its shares (spec 6.7, "Shares per period" and
/// "Prior-period adjustments").
class PeriodShares {
  /// 1 for the first period. The open period is the last one.
  final int index;

  /// True for the period after the last effective settlement.
  final bool open;

  /// The cut that closes this period. The open period uses the whole ledger.
  final Map<String, int> closingCut;

  /// The ratio this period is split at (spec 6.6, "Target rule").
  final Ratio ratio;

  /// The period's own result: only the records of this period that count in it.
  final int result;

  /// Shares of this period's own result, after loss carry-forward.
  final ProfitShares shares;

  /// Share changes from earlier periods, booked in this period.
  final ProfitShares correction;

  /// Change in the carried deficit booked in this period (corrections only).
  final int deficitChange;

  /// The carried deficit after this period.
  final int deficitAfter;

  const PeriodShares({
    required this.index,
    required this.open,
    required this.closingCut,
    required this.ratio,
    required this.result,
    required this.shares,
    required this.correction,
    required this.deficitChange,
    required this.deficitAfter,
  });
}

/// The periods of the ledger and their shares, spec 6.7.
///
/// The periods come from the effective settlements. Each period is split on
/// its own, at the ratio fixed for it. Losses are carried forward before any
/// profit is shared. A reversal of an earlier period's record is booked in the
/// period where it becomes effective, as the difference it makes to the earlier
/// period. Later settled periods are never recalculated.
///
/// Everything here is a pure function of [usable], so every phone gets the same
/// shares, in any arrival order.
List<PeriodShares> periodShares(
  Iterable<Record> usable, {
  required Set<String> partnershipKeys,
}) {
  final records = usable.toList();
  final parties = partiesOf(records);
  if (parties == null) return const [];

  // cuts[0] is before period 1. Each effective settlement closes one period.
  // The last cut is the whole ledger, and it closes the open period.
  final whole = computeEffective(records, partnershipKeys: partnershipKeys);
  final cuts = <Map<String, int>>[
    {parties.investor: 0, parties.manager: 0},
    for (final s in whole.settlements)
      if (s.state == SettlementState.effective) s.cut,
    {
      parties.investor: _highestSeq(records, parties.investor),
      parties.manager: _highestSeq(records, parties.manager),
    },
  ];
  final last = cuts.length - 1;

  // effectiveAt[c] is the effectiveness of the records inside cuts[c].
  final effectiveAt = [
    for (final cut in cuts)
      computeEffective(
        recordsInCut(records, cut),
        partnershipKeys: partnershipKeys,
      ),
  ];

  // The create's ratio is the starting ratio. It is used when no create is
  // accepted inside the cut yet (its acceptance can sit in period 1), so no
  // ratio proposal can be effective there either.
  // The validator refuses a create with a bad ratio, so this only happens when
  // the code is given records that did not come through the validator. Return
  // nothing rather than crash (decision Q3b).
  final create = records.where((r) => r.type == 'partnership_create').first;
  final startingRatio = ratioOf(create);
  if (startingRatio == null) return const [];

  // ownRecords[k - 1] and ratios[k - 1] belong to period k.
  final ownRecords = <List<Record>>[];
  final ownIds = <Set<String>>[];
  final ratios = <Ratio>[];
  for (var k = 1; k <= last; k++) {
    final own = records
        .where((r) => _isInPeriod(r, cuts[k - 1], cuts[k]))
        .toList();
    ownRecords.add(own);
    ownIds.add({for (final r in own) r.id});
    // The ratio of period k is set by the records inside the cut of period k-1.
    ratios.add(
      activeRatio(
            recordsInCut(records, cuts[k - 1]),
            effectiveness: effectiveAt[k - 1],
          )?.ratio ??
          startingRatio,
    );
  }

  // Period j's value when the reversals inside cut c (of its records) count.
  // With c == j this is the original value, with no extra records.
  _Distribution valueOf(int j, int c, int startDeficit) {
    var effectiveness = effectiveAt[j];
    if (c != j) {
      final reversals = recordsInCut(records, cuts[c]).where(
        (r) => r.type == 'reversal' && ownIds[j - 1].contains(r.refersTo),
      );
      final reversalIds = {for (final r in reversals) r.id};
      final approvals = recordsInCut(
        records,
        cuts[c],
      ).where((r) => r.type == 'approve' && reversalIds.contains(r.refersTo));
      // The reversal counts as if it had been there, with its approval.
      final extra = {
        for (final r in [...reversals, ...approvals]) r.id: r,
      };
      final withExtra = {
        for (final r in recordsInCut(records, cuts[j])) r.id: r,
        ...extra,
      }.values;
      effectiveness = computeEffective(
        withExtra,
        partnershipKeys: partnershipKeys,
      );
    }
    final result = computeMoney(
      ownRecords[j - 1],
      effectiveness: effectiveness,
    ).result;
    return _distribute(result, startDeficit);
  }

  final periods = <PeriodShares>[];
  // startDeficit[k] is the carried deficit used for period k's own shares.
  // Index 0 is unused, so the index matches the period number.
  final startDeficit = <int>[0];
  var deficit = 0;

  for (var k = 1; k <= last; k++) {
    var correctionInvestor = 0;
    var correctionManager = 0;
    var deficitChange = 0;

    // Corrections from earlier periods: the change in each one's value between
    // the cut before this period and the cut of this period.
    for (var j = 1; j < k; j++) {
      final before = valueOf(j, k - 1, startDeficit[j]);
      final after = valueOf(j, k, startDeficit[j]);
      final ratio = ratios[j - 1];
      final shareBefore = splitResult(
        before.distributable,
        investorPercent: ratio.investor,
        managerPercent: ratio.manager,
      );
      final shareAfter = splitResult(
        after.distributable,
        investorPercent: ratio.investor,
        managerPercent: ratio.manager,
      );
      correctionInvestor += shareAfter.investor - shareBefore.investor;
      correctionManager += shareAfter.manager - shareBefore.manager;
      deficitChange += after.deficitAfter - before.deficitAfter;
    }

    deficit += deficitChange;
    startDeficit.add(deficit);

    final ownResult = computeMoney(
      ownRecords[k - 1],
      effectiveness: effectiveAt[k],
    ).result;
    final own = _distribute(ownResult, deficit);
    deficit = own.deficitAfter;

    final ratio = ratios[k - 1];
    periods.add(
      PeriodShares(
        index: k,
        open: k == last,
        closingCut: cuts[k],
        ratio: ratio,
        result: ownResult,
        shares: splitResult(
          own.distributable,
          investorPercent: ratio.investor,
          managerPercent: ratio.manager,
        ),
        correction: ProfitShares(
          investor: correctionInvestor,
          manager: correctionManager,
        ),
        deficitChange: deficitChange,
        deficitAfter: deficit,
      ),
    );
  }

  return periods;
}

/// What one period leaves to share, and the deficit it leaves behind.
class _Distribution {
  final int distributable;
  final int deficitAfter;

  const _Distribution(this.distributable, this.deficitAfter);
}

/// Spec 6.7 loss carry-forward. A loss grows the deficit and gives nothing to
/// share. A profit first covers the deficit, and only the rest is shared.
_Distribution _distribute(int result, int deficit) {
  if (result < 0) return _Distribution(0, deficit - result);
  final cover = math.min(deficit, result);
  return _Distribution(result - cover, deficit - cover);
}

/// True when [r] is inside the period from [from] (exclusive) to [to]
/// (inclusive). The create is never inside a period, because it is in every cut.
bool _isInPeriod(Record r, Map<String, int> from, Map<String, int> to) {
  if (r.type == 'partnership_create') return false;
  final upper = to[r.author];
  if (upper == null || r.seq > upper) return false;
  return r.seq > (from[r.author] ?? -1);
}

/// The split of one partner's profit withdrawals, spec 6.7 "Withdrawn ahead of
/// settled profit and owed back". All three numbers come from closed periods.
class WithdrawalSplit {
  /// Effective profit withdrawals inside the last closed cut. Only the owed
  /// back and ahead split uses this. The dashboard total is
  /// [totalProfitWithdrawn], which has no closed-period limit.
  final int withdrawn;

  /// Withdrawn ahead of settled profit: neutral, not a debt.
  final int aheadOfSettled;

  /// Owed back: only the part caused by a correction that reduced a settled share.
  final int owedBack;

  const WithdrawalSplit({
    required this.withdrawn,
    required this.aheadOfSettled,
    required this.owedBack,
  });
}

/// Each partner's [WithdrawalSplit], keyed by partner key.
///
/// The labels add up: `aheadOfSettled + owedBack` is the excess of withdrawals
/// over settled shares. Nothing here is stored (hard rule 4).
Map<String, WithdrawalSplit> withdrawalSplits(
  Iterable<Record> usable, {
  required Set<String> partnershipKeys,
}) {
  final records = usable.toList();
  final parties = partiesOf(records);
  if (parties == null) return const {};

  // Closed periods only, so nothing provisional can create a debt (spec 6.7).
  final closed = periodShares(
    records,
    partnershipKeys: partnershipKeys,
  ).where((p) => !p.open).toList();
  final boundary = closed.isEmpty
      ? {parties.investor: 0, parties.manager: 0}
      : closed.last.closingCut;

  final inside = recordsInCut(records, boundary);
  final effectiveness = computeEffective(
    inside,
    partnershipKeys: partnershipKeys,
  );

  final result = <String, WithdrawalSplit>{};
  for (final partner in [parties.investor, parties.manager]) {
    var withdrawn = 0;
    for (final r in inside) {
      if (r.type == 'withdraw_request' &&
          r.author == partner &&
          r.body['kind'] == 'profit' &&
          effectiveness.isEffective(r)) {
        withdrawn += r.body['amount'] as int;
      }
    }

    var own = 0;
    var corrections = 0;
    for (final p in closed) {
      own += _shareOf(p.shares, partner, parties);
      corrections += _shareOf(p.correction, partner, parties);
    }
    final settled = own + corrections;

    // Excess before any correction, and excess now. The difference is the part
    // caused by corrections. It can only be positive when a correction reduced
    // a settled share, so an increase gives owed back 0.
    final excessBefore = math.max(0, withdrawn - own);
    final excessNow = math.max(0, withdrawn - settled);
    final owedBack = math.max(0, excessNow - excessBefore);

    result[partner] = WithdrawalSplit(
      withdrawn: withdrawn,
      aheadOfSettled: excessNow - owedBack,
      owedBack: owedBack,
    );
  }
  return result;
}

/// Each partner's total effective profit withdrawals on the whole ledger, keyed
/// by partner key (decision Q1, spec 6.7).
///
/// This has no closed-period limit, so the dashboard can show it from the first
/// withdrawal, before any settlement. It is not compared with settled profit
/// until a settlement exists. The owed back and ahead split is separate, from
/// [withdrawalSplits]. Nothing here is stored (hard rule 4).
Map<String, int> totalProfitWithdrawn(
  Iterable<Record> usable, {
  required Set<String> partnershipKeys,
}) {
  final records = usable.toList();
  final parties = partiesOf(records);
  if (parties == null) return const {};

  final effectiveness = computeEffective(
    records,
    partnershipKeys: partnershipKeys,
  );
  final totals = <String, int>{parties.investor: 0, parties.manager: 0};
  for (final r in records) {
    if (r.type == 'withdraw_request' &&
        r.body['kind'] == 'profit' &&
        effectiveness.isEffective(r)) {
      totals.update(
        r.author,
        (sum) => sum + (r.body['amount'] as int),
        ifAbsent: () => r.body['amount'] as int,
      );
    }
  }
  return totals;
}

int _shareOf(ProfitShares shares, String partner, Parties parties) =>
    partner == parties.investor ? shares.investor : shares.manager;

int _highestSeq(Iterable<Record> records, String author) {
  var highest = 0;
  for (final r in records) {
    if (r.author == author && r.seq > highest) highest = r.seq;
  }
  return highest;
}
