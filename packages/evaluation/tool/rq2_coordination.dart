// RQ2 — coordination cost. For both configs, measures what share of writes
// are coordination-free (effective without the other partner acting) versus
// needing the other partner's consent, and how many answers the other
// partner actually had to give.
//
// Classification:
//   - coordinationFree: `sale`, `expense`, `invest`, and a `reversal` whose
//     author reverses their OWN record (no consent needed — spec 6.3's
//     reversal rule only requires the other partner's consent when reversing
//     a record the reverser did not author).
//   - consentProposals: `budget_proposal`, `ratio_proposal`, `settlement`,
//     `withdraw_request`, and a `reversal` of the OTHER partner's record.
//     `partnership_create` is excluded from this split (see below) since
//     every run has exactly one, and counting it in a monthly ratio would
//     just dilute month 0.
//   - responses: `approve`/`reject` records — these are the actual
//     coordination cost, the actions the *other* partner had to take, as
//     distinct from how many proposals were raised.
//
// `partnership_create` is reported separately per run (it is always exactly
// 1), not folded into the monthly coordinationFree/consentProposals ratio.
//
// Amortization: `expense` records are coordination-free on their own, but
// each one spends against a budget that itself needed one consent round
// (a `budget_proposal` approval). `expensesPerBudgetApproval` reports how
// many stand-alone writes that one round of coordination actually covers.
//
// Usage: dart run tool/rq2_coordination.dart [seedsPerConfig]
import 'dart:io';

import 'package:evaluation/evaluation.dart';
import 'package:qirad_core/qirad_core.dart';

const _days = 90; // about three settlement cycles — see docs/evaluation/README.md.
const _hoursPerMonth = 24 * 30;

const _coordinationFreeTypes = {'sale', 'expense', 'invest'};
const _consentProposalTypes = {
  'budget_proposal',
  'ratio_proposal',
  'settlement',
  'withdraw_request',
};
const _responseTypes = {'approve', 'reject'};

Future<void> main(List<String> args) async {
  final seedsPerConfig = args.isNotEmpty ? int.parse(args[0]) : 40;

  final rowsFile = File('../../docs/evaluation/rq2_coordination.csv')
    ..writeAsStringSync(
      'config,seed,month,coordinationFree,consentProposals,responses,'
      'onlineFractionInvestor,onlineFractionManager\n',
    );

  final summaries = <String, _ConfigTotals>{};

  for (final configName in ['realistic', 'stress']) {
    final totals = _ConfigTotals();
    summaries[configName] = totals;

    for (var seed = 1; seed <= seedsPerConfig; seed++) {
      final config = configName == 'stress'
          ? WorkloadConfig.stress(days: _days)
          : WorkloadConfig.realistic(days: _days);
      final run = await generateWorkload(config, seed);
      _tallyRun(run, rowsFile, totals);

      if (seed % 10 == 0) {
        stdout.writeln('$configName: $seed/$seedsPerConfig done');
      }
    }
  }

  final summaryFile = File('../../docs/evaluation/rq2_coordination_summary.csv')
    ..writeAsStringSync(
      'config,coordinationFreeShare,consentProposalsShare,'
      'totalCoordinationFree,totalConsentProposals,totalResponses,'
      'partnershipCreateCount,expensesPerBudgetApproval,'
      'onlineFractionInvestorMin,onlineFractionInvestorMax,'
      'onlineFractionManagerMin,onlineFractionManagerMax\n',
    );
  for (final entry in summaries.entries) {
    summaryFile.writeAsStringSync(entry.value.summaryRow(entry.key), mode: FileMode.append);
  }

  stdout.writeln('wrote ${rowsFile.path} and ${summaryFile.path}');
}

/// Counts for one run, keyed by month, plus the run-level totals that don't
/// fit the monthly split (partnership_create, the amortization figures).
class _ConfigTotals {
  int coordinationFree = 0;
  int consentProposals = 0;
  int responses = 0;
  int partnershipCreateCount = 0;
  int expenses = 0;
  int effectiveBudgetApprovals = 0;

  double onlineFractionInvestorMin = double.infinity;
  double onlineFractionInvestorMax = -double.infinity;
  double onlineFractionManagerMin = double.infinity;
  double onlineFractionManagerMax = -double.infinity;

  void recordOnlineFractions(double investor, double manager) {
    if (investor < onlineFractionInvestorMin) onlineFractionInvestorMin = investor;
    if (investor > onlineFractionInvestorMax) onlineFractionInvestorMax = investor;
    if (manager < onlineFractionManagerMin) onlineFractionManagerMin = manager;
    if (manager > onlineFractionManagerMax) onlineFractionManagerMax = manager;
  }

  String summaryRow(String config) {
    final totalSplit = coordinationFree + consentProposals;
    final coordinationFreeShare = totalSplit == 0
        ? 0.0
        : coordinationFree / totalSplit;
    final consentProposalsShare = totalSplit == 0
        ? 0.0
        : consentProposals / totalSplit;
    final amortization = effectiveBudgetApprovals == 0
        ? 0.0
        : expenses / effectiveBudgetApprovals;
    return '$config,${coordinationFreeShare.toStringAsFixed(4)},'
        '${consentProposalsShare.toStringAsFixed(4)},$coordinationFree,'
        '$consentProposals,$responses,$partnershipCreateCount,'
        '${amortization.toStringAsFixed(2)},'
        '${onlineFractionInvestorMin.toStringAsFixed(4)},'
        '${onlineFractionInvestorMax.toStringAsFixed(4)},'
        '${onlineFractionManagerMin.toStringAsFixed(4)},'
        '${onlineFractionManagerMax.toStringAsFixed(4)}\n';
  }
}

void _tallyRun(WorkloadRun run, File rowsFile, _ConfigTotals totals) {
  totals.recordOnlineFractions(
    run.onlineFractionInvestor,
    run.onlineFractionManager,
  );

  final byId = <String, Record>{};
  for (final r in [...run.investorLedger, ...run.managerLedger]) {
    byId[r.id] = r;
  }

  final perMonth = <int, _MonthCounts>{};
  _MonthCounts monthFor(int hour) =>
      perMonth.putIfAbsent(hour ~/ _hoursPerMonth, () => _MonthCounts());

  for (final event in run.events) {
    final record = byId[event.recordId];

    if (event.type == 'partnership_create') {
      totals.partnershipCreateCount++;
      continue;
    }

    if (_coordinationFreeTypes.contains(event.type)) {
      monthFor(event.hour).coordinationFree++;
      totals.coordinationFree++;
      if (event.type == 'expense') totals.expenses++;
      continue;
    }

    if (event.type == 'reversal') {
      final target = record != null && record.refersTo != null
          ? byId[record.refersTo]
          : null;
      final selfReversal = target != null && target.author == record!.author;
      if (selfReversal) {
        monthFor(event.hour).coordinationFree++;
        totals.coordinationFree++;
      } else {
        monthFor(event.hour).consentProposals++;
        totals.consentProposals++;
      }
      continue;
    }

    if (_consentProposalTypes.contains(event.type)) {
      monthFor(event.hour).consentProposals++;
      totals.consentProposals++;
      continue;
    }

    if (_responseTypes.contains(event.type)) {
      monthFor(event.hour).responses++;
      totals.responses++;
      if (event.type == 'approve' &&
          record != null &&
          record.refersTo != null &&
          byId[record.refersTo]?.type == 'budget_proposal') {
        totals.effectiveBudgetApprovals++;
      }
      continue;
    }
  }

  final months = perMonth.keys.toList()..sort();
  for (final month in months) {
    final c = perMonth[month]!;
    rowsFile.writeAsStringSync(
      '${run.config.name},${run.seed},$month,${c.coordinationFree},'
      '${c.consentProposals},${c.responses},'
      '${run.onlineFractionInvestor.toStringAsFixed(4)},'
      '${run.onlineFractionManager.toStringAsFixed(4)}\n',
      mode: FileMode.append,
    );
  }
}

class _MonthCounts {
  int coordinationFree = 0;
  int consentProposals = 0;
  int responses = 0;
}
