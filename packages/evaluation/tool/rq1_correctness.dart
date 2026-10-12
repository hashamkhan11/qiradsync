// RQ1 — correctness of delta sync. Runs several hundred fresh seeds per
// config, each about a month (see docs/evaluation/README.md's "Run
// lengths"), and for every run:
//
//   1. Reconstructs both devices' ledgers through the REAL sync protocol
//      primitives (`firstMissingSeqs`, `Ledger.versionVector()`) against an
//      in-memory relay (`RelaySim`), instead of trusting the generator's own
//      internal direct-delivery queues — the generator's queues exist for
//      simulation speed, not as a stand-in for the sync protocol itself.
//   2. Checks both devices converge to identical records.
//   3. Checks both devices compute identical dashboard numbers.
//   4. Checks a closed period's shares never change once more records
//      arrive after its cut (spec 6.7's "later settled periods are never
//      recalculated"), by recomputing it in isolation and comparing.
//   5. Checks no stored budget ever went negative (no own write over
//      budget).
//   6. Checks the run raised no false alarms: zero equivocation flags and
//      zero chain-invalid records on both devices, since this is an honest
//      run with no attacks.
//
// Every failing check is also written to rq1_failures.csv with the seed and
// the first differing record or value, so it is reproducible.
//
// Usage: dart run tool/rq1_correctness.dart [seedsPerConfig]
import 'dart:io';

import 'package:evaluation/evaluation.dart';
import 'package:qirad_core/qirad_core.dart';

const _days = 30; // "about a month" — see docs/evaluation/README.md.
const _maxRepairRounds = 3; // spec 7.3's own repair-round limit.

Future<void> main(List<String> args) async {
  final seedsPerConfig = args.isNotEmpty ? int.parse(args[0]) : 300;

  final resultsFile = File('../../docs/evaluation/rq1_correctness.csv')
    ..writeAsStringSync(
      'config,seed,records,syncProtocolConverged,identicalRecords,'
      'dashboardMatch,settlementStable,budgetSafe,noFalseAlarms\n',
    );
  final failuresFile = File('../../docs/evaluation/rq1_failures.csv')
    ..writeAsStringSync('config,seed,check,detail\n');

  for (final configName in ['realistic', 'stress']) {
    for (var seed = 1; seed <= seedsPerConfig; seed++) {
      final config = configName == 'stress'
          ? WorkloadConfig.stress(days: _days)
          : WorkloadConfig.realistic(days: _days);
      final run = await generateWorkload(config, seed);
      final row = await _checkRun(configName, seed, run, failuresFile);
      resultsFile.writeAsStringSync(row, mode: FileMode.append);

      if (seed % 25 == 0) {
        stdout.writeln('$configName: $seed/$seedsPerConfig done');
      }
    }
  }
  stdout.writeln('wrote ${resultsFile.path} and ${failuresFile.path}');
}

Future<String> _checkRun(
  String configName,
  int seed,
  WorkloadRun run,
  File failuresFile,
) async {
  void fail(String check, String detail) {
    failuresFile.writeAsStringSync(
      '$configName,$seed,$check,"${detail.replaceAll('"', '""')}"\n',
      mode: FileMode.append,
    );
  }

  final keys = {run.investor.key, run.manager.key};
  final resync = await _resyncThroughRelay(run);
  final syncProtocolConverged = resync.converged;
  if (!syncProtocolConverged) {
    fail(
      'syncProtocolConverged',
      'did not converge within $_maxRepairRounds repair rounds',
    );
  }

  final investorUsable = resync.investor.usableRecords.toList();
  final managerUsable = resync.manager.usableRecords.toList();
  final identicalRecords = _sameIds(investorUsable, managerUsable);
  if (!identicalRecords) {
    fail('identicalRecords', _firstDifferingId(investorUsable, managerUsable));
  }

  var dashboardMatch = false;
  var settlementStable = true;
  var budgetSafe = true;

  if (identicalRecords) {
    final investorDashboard = buildDashboard(
      investorUsable,
      partnershipKeys: keys,
    );
    final managerDashboard = buildDashboard(
      managerUsable,
      partnershipKeys: keys,
    );
    dashboardMatch = _dashboardEquals(investorDashboard, managerDashboard);
    if (!dashboardMatch) {
      fail(
        'dashboardMatch',
        'investor result=${investorDashboard.money.result} '
        'manager result=${managerDashboard.money.result}',
      );
    }

    final periods = periodShares(investorUsable, partnershipKeys: keys);
    for (final period in periods) {
      if (period.open) continue;
      final cutRecords = recordsInCut(investorUsable, period.closingCut);
      final recomputed = periodShares(cutRecords, partnershipKeys: keys).last;
      if (recomputed.result != period.result ||
          recomputed.shares.investor != period.shares.investor ||
          recomputed.shares.manager != period.shares.manager ||
          recomputed.correction.investor != period.correction.investor ||
          recomputed.correction.manager != period.correction.manager ||
          recomputed.deficitAfter != period.deficitAfter) {
        settlementStable = false;
        fail(
          'settlementStable',
          'period ${period.index} result was ${period.result} share '
          '(${period.shares.investor},${period.shares.manager}), now '
          'recomputes to ${recomputed.result} share '
          '(${recomputed.shares.investor},${recomputed.shares.manager})',
        );
        break;
      }
    }

    final effectiveness = computeEffective(investorUsable, partnershipKeys: keys);
    final money = computeMoney(investorUsable, effectiveness: effectiveness);
    for (final entry in money.budgetLeft.entries) {
      if (entry.value < 0) {
        budgetSafe = false;
        fail('budgetSafe', 'budget ${entry.key} left=${entry.value}');
        break;
      }
    }
  }

  final noFalseAlarms =
      run.investor.validator.equivocatingFromSeq.isEmpty &&
      run.investor.validator.chainInvalidIds.isEmpty &&
      run.manager.validator.equivocatingFromSeq.isEmpty &&
      run.manager.validator.chainInvalidIds.isEmpty &&
      resync.investor.equivocatingFromSeq.isEmpty &&
      resync.investor.chainInvalidIds.isEmpty &&
      resync.manager.equivocatingFromSeq.isEmpty &&
      resync.manager.chainInvalidIds.isEmpty;
  if (!noFalseAlarms) {
    fail(
      'noFalseAlarms',
      'equivocating=${run.investor.validator.equivocatingFromSeq}'
      '/${run.manager.validator.equivocatingFromSeq} '
      'chainInvalid=${run.investor.validator.chainInvalidIds}'
      '/${run.manager.validator.chainInvalidIds}',
    );
  }

  return '$configName,$seed,${investorUsable.length},$syncProtocolConverged,'
      '$identicalRecords,$dashboardMatch,$settlementStable,$budgetSafe,'
      '$noFalseAlarms\n';
}

/// Rebuilds both devices' ledgers from scratch, through an in-memory relay
/// and the real `firstMissingSeqs`/version-vector decision logic, starting
/// only from what each device itself authored — this is the "sync through
/// the real delta logic" the plan asked for, independent of the generator's
/// own internal direct-delivery shortcut.
Future<_ResyncResult> _resyncThroughRelay(WorkloadRun run) async {
  final relay = RelaySim();
  final investorFresh = Validator(
    pinnedInvestorKey: run.investor.key,
    pinnedManagerKey: run.manager.key,
  );
  final managerFresh = Validator(
    pinnedInvestorKey: run.investor.key,
    pinnedManagerKey: run.manager.key,
  );

  final investorOwnTexts = _ownTexts(run.investor.validator, run.investor.key);
  final managerOwnTexts = _ownTexts(run.manager.validator, run.manager.key);

  var converged = false;
  for (var round = 0; round <= _maxRepairRounds; round++) {
    final investorReply = relay.sync(
      clientVector: investorFresh.ledger.versionVector(),
      uploads: round == 0 ? investorOwnTexts : const [],
    );
    for (final text in [...investorReply.records, ...investorReply.conflicts]) {
      await investorFresh.receiveText(text);
    }

    final managerReply = relay.sync(
      clientVector: managerFresh.ledger.versionVector(),
      uploads: round == 0 ? managerOwnTexts : const [],
    );
    for (final text in [...managerReply.records, ...managerReply.conflicts]) {
      await managerFresh.receiveText(text);
    }

    final relayVector = managerReply.vector;
    final investorMissing = firstMissingSeqs(
      local: relayVector,
      relay: investorFresh.ledger.versionVector(),
    );
    final managerMissing = firstMissingSeqs(
      local: relayVector,
      relay: managerFresh.ledger.versionVector(),
    );
    if (investorMissing.isEmpty && managerMissing.isEmpty) {
      converged = true;
      break;
    }
  }

  return _ResyncResult(
    investor: investorFresh,
    manager: managerFresh,
    converged: converged,
  );
}

List<String> _ownTexts(Validator original, String authorKey) {
  final own = original.ledger.records.where((r) => r.author == authorKey)
      .toList()
    ..sort((a, b) => a.seq.compareTo(b.seq));
  return [for (final r in own) canonicalJson(r.toJson())];
}

bool _sameIds(List<Record> a, List<Record> b) {
  final idsA = a.map((r) => r.id).toSet();
  final idsB = b.map((r) => r.id).toSet();
  return idsA.length == idsB.length && idsA.containsAll(idsB);
}

String _firstDifferingId(List<Record> a, List<Record> b) {
  final idsA = a.map((r) => r.id).toSet();
  final idsB = b.map((r) => r.id).toSet();
  final onlyInA = idsA.difference(idsB);
  final onlyInB = idsB.difference(idsA);
  if (onlyInA.isNotEmpty) return 'investor-only record ${onlyInA.first}';
  return 'manager-only record ${onlyInB.first}';
}

bool _dashboardEquals(Dashboard a, Dashboard b) {
  return a.money.capital == b.money.capital &&
      a.money.cashBalance == b.money.cashBalance &&
      a.money.result == b.money.result &&
      a.money.profitPaid == b.money.profitPaid &&
      _mapEquals(a.money.budgetLeft, b.money.budgetLeft) &&
      a.ratio?.ratio.investor == b.ratio?.ratio.investor &&
      a.ratio?.ratio.manager == b.ratio?.ratio.manager &&
      a.shares?.investor == b.shares?.investor &&
      a.shares?.manager == b.shares?.manager &&
      a.ratioChanged == b.ratioChanged &&
      a.partnershipStatus == b.partnershipStatus;
}

bool _mapEquals(Map<String, int> a, Map<String, int> b) {
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (b[entry.key] != entry.value) return false;
  }
  return true;
}

class _ResyncResult {
  _ResyncResult({
    required this.investor,
    required this.manager,
    required this.converged,
  });

  final Validator investor;
  final Validator manager;
  final bool converged;
}
