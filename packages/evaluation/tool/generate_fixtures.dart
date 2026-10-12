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
import 'dart:convert';
import 'dart:io';

import 'package:evaluation/evaluation.dart';

/// One seed per (config, length) is enough here: RQ3 studies performance vs.
/// size, not run-to-run variance, and RQ1/RQ2's own many-seeds runs are short
/// enough not to need caching.
const _seed = 123;

Future<void> main(List<String> args) async {
  final force = args.contains('--force');
  final dataDir = Directory('data')..createSync(recursive: true);

  const jobs = [
    ('realistic', '1month', 30),
    ('realistic', '12months', 365),
    ('realistic', '10years', 3650),
    ('stress', '1month', 30),
    ('stress', '12months', 365),
  ];

  for (final (configName, label, days) in jobs) {
    final file = File('${dataDir.path}/${configName}_seed${_seed}_$label.json');
    if (file.existsSync() && !force) {
      stdout.writeln('skip  $configName/$label (already cached)');
      continue;
    }

    final config = configName == 'stress'
        ? WorkloadConfig.stress(days: days)
        : WorkloadConfig.realistic(days: days);

    stdout.writeln('build $configName/$label (days=$days seed=$_seed) ...');
    final sw = Stopwatch()..start();
    final run = await generateWorkload(config, _seed);
    sw.stop();

    final json = {
      'config': configName,
      'seed': _seed,
      'days': days,
      'generationMs': sw.elapsedMilliseconds,
      'investorKey': run.investor.key,
      'managerKey': run.manager.key,
      'partnershipId': run.partnershipId,
      // The order records were authored in, so a benchmark can take a
      // size-N prefix that is a real run shape, not a lexical slice of the
      // final ledger.
      'events': [for (final e in run.events) e.toJson()],
      'investorLedger': [for (final r in run.investorLedger) r.toJson()],
      'managerLedger': [for (final r in run.managerLedger) r.toJson()],
    };
    file.writeAsStringSync(jsonEncode(json));

    stdout.writeln(
      'done  $configName/$label elapsedMs=${sw.elapsedMilliseconds} '
      'investorRecords=${run.investorLedger.length} '
      'managerRecords=${run.managerLedger.length}',
    );
  }
}
