import 'package:qirad_core/qirad_core.dart';

import 'device.dart';
import 'workload_config.dart';

/// Which simulated device authored or answered something.
enum Actor { investor, manager }

/// One record the generator wrote (self-authored and self-received; see
/// `workload_generator.dart` for how it is then delivered to the other
/// device). Kept so a result file can report what actually happened, not
/// just the final ledger.
class WorkloadEvent {
  const WorkloadEvent({
    required this.hour,
    required this.recordId,
    required this.type,
    required this.author,
  });

  /// The simulated hour (0-based) this record was authored at.
  final int hour;
  final String recordId;
  final String type;
  final Actor author;

  Map<String, Object?> toJson() => {
    'hour': hour,
    'recordId': recordId,
    'type': type,
    'author': author.name,
  };
}

/// One attempt the generator made that core refused, before anything was
/// written — exactly the refusals `proposalRefusal`, `answerEligibility` and
/// `answerConsent` are for. Logged so RQ2's coordination-cost classification
/// (a later step) has real refusal counts to work from, instead of numbers
/// the simulation invented.
class RefusalEvent {
  const RefusalEvent({
    required this.hour,
    required this.stage,
    required this.type,
    required this.actor,
    required this.reason,
  });

  final int hour;

  /// `proposal`, `answerEligibility` or `answerConsent`.
  final String stage;
  final String type;
  final Actor actor;
  final String reason;

  Map<String, Object?> toJson() => {
    'hour': hour,
    'stage': stage,
    'type': type,
    'actor': actor.name,
    'reason': reason,
  };
}

/// The result of one seeded run of the workload generator: the config and
/// seed that produced it (so it can be reproduced), both devices' final
/// ledgers, and a log of what happened. [toJson] writes the config in full,
/// per the requirement that every result file carries the exact parameters
/// that produced it.
class WorkloadRun {
  const WorkloadRun({
    required this.config,
    required this.seed,
    required this.partnershipId,
    required this.investor,
    required this.manager,
    required this.events,
    required this.refusals,
    required this.onlineFractionInvestor,
    required this.onlineFractionManager,
  });

  final WorkloadConfig config;
  final int seed;
  final String partnershipId;
  final Device investor;
  final Device manager;
  final List<WorkloadEvent> events;
  final List<RefusalEvent> refusals;

  /// Share of the run's hours each device's precomputed schedule marked it
  /// online (day 0 is always online; see `workload_generator.dart`'s
  /// `_buildOnlineSchedule`). Recorded per run so RQ1/RQ2 can report the
  /// actual connectivity a run saw, not just the config's intended ranges.
  final double onlineFractionInvestor;
  final double onlineFractionManager;

  /// The records the investor's device holds at the end of the run, sorted
  /// by author then seq, so two runs with the same seed always print the
  /// same order (hard rule 5: deterministic, sort explicitly).
  List<Record> get investorLedger => _sorted(investor.validator.ledger.records);

  /// The records the manager's device holds at the end of the run.
  List<Record> get managerLedger => _sorted(manager.validator.ledger.records);

  Map<String, Object?> toJson() => {
    'config': config.toJson(),
    'seed': seed,
    'partnershipId': partnershipId,
    'investorKey': investor.key,
    'managerKey': manager.key,
    'investorRecordCount': investorLedger.length,
    'managerRecordCount': managerLedger.length,
    'events': [for (final e in events) e.toJson()],
    'refusals': [for (final r in refusals) r.toJson()],
    'onlineFractionInvestor': onlineFractionInvestor,
    'onlineFractionManager': onlineFractionManager,
  };
}

List<Record> _sorted(Iterable<Record> records) =>
    records.toList()..sort((a, b) {
      final byAuthor = a.author.compareTo(b.author);
      return byAuthor != 0 ? byAuthor : a.seq.compareTo(b.seq);
    });
