// RQ3's other half: plan.md's Phase 8 checklist asks for sync payload size
// (full vs delta) at 100 / 1,000 / 10,000 records, which is a different
// question from `benchmark_recalc.dart`'s recalculation *time* — this
// measures *bytes*, using the same cached fixture, no new simulation runs.
//
// "Full" is the canonical JSON (spec 7.2: "Records travel as the exact
// canonical JSON string the author produced") of every record up to size N —
// what a brand-new device downloads on its very first sync. "Delta" is what
// a device that already has most of the ledger downloads on one ordinary
// sync: the small version vector it sends (spec 7.1), plus the records the
// relay sends back because their `seq` is past that vector.
//
// The cached fixture's `events` log records only *when a record was
// authored*, not when each sync call happened or what it carried (that
// instrumentation does not exist — see docs/evaluation/README.md). So "one
// ordinary sync" is approximated here as "one day": for each day in the
// prefix, the records authored that day stand in for what the next sync
// would have picked up, since the generator's devices sync whenever they are
// online and online fractions are high (see WorkloadRun.onlineFraction*).
// This is a proxy, not a replay of real sync calls — it is stated as such in
// the README, not hidden.
//
// Usage: dart run tool/rq3b_sync_size.dart [fixturePath]
import 'dart:convert';
import 'dart:io';

import 'package:qirad_core/qirad_core.dart';

const _sizes = [100, 1000, 2500, 5000, 10000];

Future<void> main(List<String> args) async {
  final path = args.isNotEmpty ? args[0] : 'data/realistic_seed123_5years.json';
  final json = jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>;

  final ledgerJson = json['managerLedger'] as List<Object?>;
  final byId = <String, Record>{};
  for (final r in ledgerJson) {
    final record = Record.fromJson(r as Map<String, dynamic>);
    byId[record.id] = record;
  }

  // Authorship order and day, filtered to records this ledger actually has —
  // same filtering `benchmark_recalc.dart` uses, so a size-N prefix here is
  // the same N records that tool measured recalculation time against.
  final eventsJson = json['events'] as List<Object?>;
  final orderedEvents = [
    for (final e in eventsJson) e as Map<String, Object?>,
  ].where((e) => byId.containsKey(e['recordId'] as String)).toList();

  stdout.writeln('fixture: $path (${orderedEvents.length} records available)');

  final rows = <String>[
    'records,fullBytes,deltaRecordsMedian,deltaBytesMedian,vectorBytes,deltaTotalBytes,ratio',
  ];
  stdout.writeln(
    'records\tfullBytes\tdeltaRecords(median)\tdeltaBytes(median)\tvectorBytes\tratio',
  );

  for (final size in _sizes) {
    if (size > orderedEvents.length) break;
    final prefixEvents = orderedEvents.take(size).toList();
    final prefixRecords = [
      for (final e in prefixEvents) byId[e['recordId'] as String]!,
    ];

    final fullBytes = prefixRecords
        .map((r) => utf8.encode(canonicalJson(r.toJson())).length)
        .fold<int>(0, (a, b) => a + b);

    final ledger = Ledger();
    for (final r in prefixRecords) {
      ledger.add(r);
    }
    final vector = ledger.versionVector();
    final vectorBytes = utf8.encode(canonicalJson(vector)).length;

    // Bucket by simulated day (24 hours/tick), as this run's stand-in for
    // "what one ordinary sync delivered" — see the file header.
    final recordsByDay = <int, List<Record>>{};
    for (final e in prefixEvents) {
      final day = (e['hour'] as int) ~/ 24;
      recordsByDay.putIfAbsent(day, () => []).add(byId[e['recordId'] as String]!);
    }
    final dayCounts = <int>[];
    final dayBytes = <int>[];
    for (final dayRecords in recordsByDay.values) {
      dayCounts.add(dayRecords.length);
      dayBytes.add(
        dayRecords
            .map((r) => utf8.encode(canonicalJson(r.toJson())).length)
            .fold<int>(0, (a, b) => a + b),
      );
    }
    final deltaRecordsMedian = _median(dayCounts);
    final deltaBytesMedian = _median(dayBytes);
    final deltaTotalBytes = deltaBytesMedian + vectorBytes;
    final ratio = fullBytes / deltaTotalBytes;

    stdout.writeln(
      '$size\t$fullBytes\t\t$deltaRecordsMedian\t\t\t$deltaBytesMedian'
      '\t\t\t$vectorBytes\t\t${ratio.toStringAsFixed(1)}x',
    );
    rows.add(
      '$size,$fullBytes,$deltaRecordsMedian,$deltaBytesMedian,$vectorBytes,'
      '$deltaTotalBytes,${ratio.toStringAsFixed(2)}',
    );
  }

  File('../../docs/evaluation/rq3_sync_size.csv').writeAsStringSync(
    '${rows.join('\n')}\n',
  );
}

/// The median of a non-empty int list — an actual element, not an average,
/// so the reported "typical sync" is a real sync that happened, not a
/// number no single day produced (same reasoning as `benchmark_recalc.dart`'s
/// own median-of-reps, applied to days instead of reps).
int _median(List<int> values) {
  final sorted = [...values]..sort();
  return sorted[sorted.length ~/ 2];
}
