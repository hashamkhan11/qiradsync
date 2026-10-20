// Measures the real per-call cost of the three full-ledger-recompute
// functions the app's own screens call on every rebuild — `approvalsInbox`,
// `computeEffective` and `buildDashboard` — at several ledger sizes, using
// size-N *prefixes* (in authorship order) of an already-generated fixture.
//
// This exists because the workload generator's own interleaved timings (see
// docs/evaluation/README.md's "Where the time goes") mix call *frequency*
// and call *cost* together, and are measured under Dart's JIT, which adds
// noise. This tool isolates per-call cost in a compiled binary, with
// warm-up and repetition, so the numbers are a real RQ3 measurement rather
// than a guess at a growth curve.
//
// Usage (compiled, for stable timings — JIT warm-up noise is exactly what
// this tool exists to avoid):
//   dart compile exe tool/benchmark_recalc.dart -o tool/benchmark_recalc.exe
//   ./tool/benchmark_recalc.exe data/realistic_seed123_10years.json
import 'dart:convert';
import 'dart:io';

import 'package:qirad_core/qirad_core.dart';

/// Ledger sizes to measure at, clipped to what the fixture actually has.
const _sizes = [100, 1000, 2500, 3751, 5000, 10000];

const _warmupReps = 5;
const _timedReps = 31; // odd, so "median" is an actual element, not an average.

Future<void> main(List<String> args) async {
  final path = args.isNotEmpty
      ? args[0]
      : 'data/realistic_seed123_10years.json';
  final json = jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>;

  final investorKey = json['investorKey'] as String;
  final managerKey = json['managerKey'] as String;
  final partnershipKeys = {investorKey, managerKey};

  // The manager ledger is the more complete one by the end of a run (the
  // manager authors the most record types), and by then both sides have
  // converged on almost the same records anyway.
  final ledgerJson = json['managerLedger'] as List<Object?>;
  final byId = <String, Record>{};
  for (final r in ledgerJson) {
    final record = Record.fromJson(r as Map<String, dynamic>);
    byId[record.id] = record;
  }

  // Authorship order, filtered to records this ledger actually has, so a
  // size-N prefix is a real run shape (each author's own chain stays
  // contiguous) rather than an arbitrary slice.
  final eventsJson = json['events'] as List<Object?>;
  final orderedIds = [
    for (final e in eventsJson)
      (e as Map<String, Object?>)['recordId'] as String,
  ].where(byId.containsKey).toList();

  stdout.writeln('fixture: $path (${orderedIds.length} records available)');
  stdout.writeln(
    'size\tapprovalsInbox(ms)\tcomputeEffective(ms)\tbuildDashboard(ms)',
  );

  for (final size in _sizes) {
    if (size > orderedIds.length) break;
    final prefixIds = orderedIds.take(size).toSet();
    final prefix = [
      for (final id in orderedIds.take(size)) byId[id]!,
    ];
    assert(prefix.length == prefixIds.length);

    final inboxMs = _timeMedianMs(
      () => approvalsInbox(
        prefix,
        partnershipKeys: partnershipKeys,
        myKey: investorKey,
      ),
    );
    final effectiveMs = _timeMedianMs(
      () => computeEffective(prefix, partnershipKeys: partnershipKeys),
    );
    final dashboardMs = _timeMedianMs(
      () => buildDashboard(prefix, partnershipKeys: partnershipKeys),
    );

    stdout.writeln(
      '$size\t${inboxMs.toStringAsFixed(2)}\t\t\t'
      '${effectiveMs.toStringAsFixed(2)}\t\t\t${dashboardMs.toStringAsFixed(2)}',
    );
  }
}

/// Runs [call] [_warmupReps] times unmeasured, then [_timedReps] times
/// measured, and returns the median elapsed microseconds in milliseconds —
/// the median, not the mean, so one GC pause or OS scheduling hiccup in a
/// single rep cannot skew the reported number.
double _timeMedianMs(Object? Function() call) {
  for (var i = 0; i < _warmupReps; i++) {
    call();
  }
  final samplesUs = <int>[];
  for (var i = 0; i < _timedReps; i++) {
    final sw = Stopwatch()..start();
    call();
    sw.stop();
    samplesUs.add(sw.elapsedMicroseconds);
  }
  samplesUs.sort();
  return samplesUs[samplesUs.length ~/ 2] / 1000;
}
