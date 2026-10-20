// Generates the large ledgers RQ3 and the cached RQ1/RQ2 runs need, once per
// seed, and caches them as files under `packages/evaluation/data/`
// (gitignored: these are large and reproducible from `(config, seed, days)`
// alone, so they do not belong in the public repo).
//
// RQ3 studies performance vs. ledger size, so it only needs the `realistic`
// config's size ladder (about 1 month, 12 months and 10 years, landing close
// to 100 / 1,000 / 10,000 records — see docs/evaluation/README.md). `stress`
// is for RQ1/RQ2 (correctness and coordination cost under pressure), which
// only need the two shorter lengths.
//
// Each file also keeps the authorship order (`events`), not just the final
// ledger, so a later benchmark can take a size-N *prefix* of the run in the
// order records actually happened — not an arbitrary slice.
//
// Usage:
//   dart run tool/generate_fixtures.dart          # generate anything missing
//   dart run tool/generate_fixtures.dart --force  # regenerate everything
//   dart run tool/generate_fixtures.dart --only=realistic_3years,realistic_5years
//                                                  # run only the named jobs
//   dart run tool/generate_fixtures.dart --cap-minutes=180
//                                                  # give up on a job past this long
//
// Each job runs in its own isolate, and the cap is a `Timer` in the *main*
// isolate racing against the worker isolate's completion — not an external
// `timeout` wrapper (on Windows, `timeout`'s SIGTERM does not reach a native
// `dart.exe` child, so that cap can silently fail to stop anything) and not
// a same-isolate `Future.delayed` race either (a CPU-bound async function's
// own microtask chain can starve a same-isolate Timer indefinitely, so it
// may never fire). A Timer in the main isolate is unaffected by either
// problem, and when it wins, the worker isolate is killed outright so no
// orphaned computation keeps consuming CPU.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:evaluation/evaluation.dart';

/// One seed per (config, length) is enough here: RQ3 studies performance vs.
/// size, not run-to-run variance, and RQ1/RQ2's own many-seeds runs are short
/// enough not to need caching.
const _seed = 123;

class _JobRequest {
  _JobRequest(this.configName, this.days, this.seed, this.commitHash, this.replyTo);
  final String configName;
  final int days;
  final int seed;
  final String commitHash;
  final SendPort replyTo;
}

/// Runs in a worker isolate: generates the workload and sends back the
/// finished fixture JSON (already encoded, so the only thing crossing the
/// isolate boundary is a plain String) plus the numbers the log line reports.
void _runJob(_JobRequest req) async {
  final config = req.configName == 'stress'
      ? WorkloadConfig.stress(days: req.days)
      : WorkloadConfig.realistic(days: req.days);

  final sw = Stopwatch()..start();
  final run = await generateWorkload(config, req.seed);
  sw.stop();

  final json = {
    'config': req.configName,
    'seed': req.seed,
    'days': req.days,
    'generatorCommit': req.commitHash,
    'generationMs': sw.elapsedMilliseconds,
    'investorKey': run.investor.key,
    'managerKey': run.manager.key,
    'partnershipId': run.partnershipId,
    'onlineFractionInvestor': run.onlineFractionInvestor,
    'onlineFractionManager': run.onlineFractionManager,
    // The order records were authored in, so a benchmark can take a size-N
    // prefix that is a real run shape, not a lexical slice of the final
    // ledger.
    'events': [for (final e in run.events) e.toJson()],
    'investorLedger': [for (final r in run.investorLedger) r.toJson()],
    'managerLedger': [for (final r in run.managerLedger) r.toJson()],
  };

  req.replyTo.send({
    'fixtureJson': jsonEncode(json),
    'elapsedMs': sw.elapsedMilliseconds,
    'investorRecords': run.investorLedger.length,
    'managerRecords': run.managerLedger.length,
  });
}

/// Returns the job's result, or `null` if [cap] elapsed first (in which case
/// the worker isolate is killed and nothing is written for this job).
Future<Map<String, dynamic>?> _generateWithCap({
  required String configName,
  required int days,
  required int seed,
  required String commitHash,
  Duration? cap,
}) async {
  final resultPort = ReceivePort();
  final errorPort = ReceivePort();
  final isolate = await Isolate.spawn(
    _runJob,
    _JobRequest(configName, days, seed, commitHash, resultPort.sendPort),
    onError: errorPort.sendPort,
    errorsAreFatal: true,
  );

  final completer = Completer<Map<String, dynamic>?>();
  resultPort.listen((message) {
    if (!completer.isCompleted) {
      completer.complete(Map<String, dynamic>.from(message as Map));
    }
  });
  errorPort.listen((error) {
    if (!completer.isCompleted) {
      completer.completeError(StateError('fixture worker isolate error: $error'));
    }
  });
  final timer = cap == null
      ? null
      : Timer(cap, () {
          if (!completer.isCompleted) completer.complete(null);
        });

  try {
    return await completer.future;
  } finally {
    timer?.cancel();
    resultPort.close();
    errorPort.close();
    isolate.kill(priority: Isolate.immediate);
  }
}

Future<void> main(List<String> args) async {
  final force = args.contains('--force');
  final onlyArg = args.firstWhere(
    (a) => a.startsWith('--only='),
    orElse: () => '',
  );
  final only = onlyArg.isEmpty
      ? null
      : onlyArg.substring('--only='.length).split(',').toSet();
  final capArg = args.firstWhere(
    (a) => a.startsWith('--cap-minutes='),
    orElse: () => '',
  );
  final cap = capArg.isEmpty
      ? null
      : Duration(minutes: int.parse(capArg.substring('--cap-minutes='.length)));
  final dataDir = Directory('data')..createSync(recursive: true);
  // Recorded in every fixture file so a later analysis can tell which
  // generator version produced it — fixtures are cached and reused across
  // many commits, so this is the only way to know they all came from the
  // same code (the user's explicit requirement after a schedule-generator
  // bug fix made every previously-cached fixture stale).
  final commitHash = Process.runSync(
    'git',
    ['rev-parse', 'HEAD'],
  ).stdout.toString().trim();

  const jobs = [
    ('realistic', '1month', 30),
    ('realistic', '12months', 365),
    ('realistic', '10years', 3650),
    // Fallback rungs for the size ladder: added after a 10-year run did not
    // finish within its time cap, so the ladder's top end is whichever of
    // these actually completes (see docs/evaluation/README.md).
    ('realistic', '3years', 1095),
    ('realistic', '5years', 1825),
    ('stress', '1month', 30),
    ('stress', '12months', 365),
  ];

  for (final (configName, label, days) in jobs) {
    final name = '${configName}_$label';
    if (only != null && !only.contains(name)) continue;
    final file = File('${dataDir.path}/${configName}_seed${_seed}_$label.json');
    if (file.existsSync() && !force) {
      stdout.writeln('skip  $configName/$label (already cached)');
      continue;
    }

    stdout.writeln('build $configName/$label (days=$days seed=$_seed) ...');
    final result = await _generateWithCap(
      configName: configName,
      days: days,
      seed: _seed,
      commitHash: commitHash,
      cap: cap,
    );

    if (result == null) {
      stdout.writeln(
        'cap reached for $configName/$label after ${cap!.inMinutes}min — '
        'stopping, no fixture written',
      );
      exit(1);
    }

    file.writeAsStringSync(result['fixtureJson'] as String);
    stdout.writeln(
      'done  $configName/$label elapsedMs=${result['elapsedMs']} '
      'investorRecords=${result['investorRecords']} '
      'managerRecords=${result['managerRecords']}',
    );
  }
}
