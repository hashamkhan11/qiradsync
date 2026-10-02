import 'dart:math';

import 'package:qirad_core/qirad_core.dart';
import 'package:test/test.dart';

Record _record({required String id, required String author, required int seq}) {
  return Record(
    v: 1,
    id: id,
    partnership: 'p1',
    author: author,
    seq: seq,
    prevHash: '0' * 64,
    type: 'partnership_create',
    body: const {},
    refersTo: null,
    note: '',
    time: '2026-10-02T10:15:00Z',
    sig: 'sig',
  );
}

void main() {
  test(
    'merging the same records in any order or grouping, with duplicates, '
    'always gives an identical ledger (1000 random cases, fixed seed)',
    () {
      // Fixed seed: this test is deterministic and reproducible, not a
      // flaky fuzz test — a failure always points at the same case.
      final random = Random(1234);
      const authors = ['alice', 'bob'];

      for (var iteration = 0; iteration < 1000; iteration++) {
        // 1. Build a batch of unique records.
        final recordCount = 5 + random.nextInt(20);
        final seqByAuthor = <String, int>{};
        final uniqueRecords = <Record>[];
        for (var i = 0; i < recordCount; i++) {
          final author = authors[random.nextInt(authors.length)];
          final seq = (seqByAuthor[author] ?? 0) + 1;
          seqByAuthor[author] = seq;
          uniqueRecords.add(_record(id: 'r$iteration-$i', author: author, seq: seq));
        }

        // 2. Duplicate a random few, so the batch has real repeats in it.
        final withDuplicates = [...uniqueRecords];
        final duplicateCount = random.nextInt(uniqueRecords.length);
        for (var i = 0; i < duplicateCount; i++) {
          withDuplicates.add(uniqueRecords[random.nextInt(uniqueRecords.length)]);
        }
        withDuplicates.shuffle(random);

        // 3. Baseline: add everything to one ledger, in this shuffled order.
        final baseline = Ledger();
        for (final record in withDuplicates) {
          baseline.add(record);
        }

        // 4. Comparison: split into two random groups, build each
        // separately, then merge. The grouping and each group's internal
        // order are both randomised independently of the baseline's order.
        final splitPoint = random.nextInt(withDuplicates.length + 1);
        final shuffledForSplit = [...withDuplicates]..shuffle(random);
        final groupA = Ledger();
        for (final record in shuffledForSplit.take(splitPoint)) {
          groupA.add(record);
        }
        final groupB = Ledger();
        for (final record in shuffledForSplit.skip(splitPoint)) {
          groupB.add(record);
        }
        final merged = groupA.merge(groupB);

        // Same set of ids and the same version vector, regardless of the
        // order or grouping used to build up to it.
        expect(
          merged.records.map((r) => r.id).toSet(),
          baseline.records.map((r) => r.id).toSet(),
          reason: 'iteration $iteration',
        );
        expect(
          merged.versionVector(),
          baseline.versionVector(),
          reason: 'iteration $iteration',
        );
      }
    },
  );
}
