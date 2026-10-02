import 'package:qirad_core/qirad_core.dart';
import 'package:test/test.dart';

Record _record({
  required String id,
  String author = 'author1',
  int seq = 1,
  String note = '',
}) {
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
    note: note,
    time: '2026-10-02T10:15:00Z',
    sig: 'sig',
  );
}

void main() {
  group('Ledger.merge', () {
    test('union of disjoint ledgers holds every record', () {
      final a = Ledger()..add(_record(id: 'r1'));
      final b = Ledger()..add(_record(id: 'r2'));

      final merged = a.merge(b);

      expect(merged.records.map((r) => r.id).toSet(), {'r1', 'r2'});
    });

    test('a record known to both ledgers is not duplicated', () {
      final shared = _record(id: 'r1');
      final a = Ledger()..add(shared);
      final b = Ledger()..add(shared)..add(_record(id: 'r2'));

      final merged = a.merge(b);

      expect(merged.records.length, 2);
    });

    test('merge(a, b) equals merge(b, a), even with an id conflict', () {
      final a = Ledger()
        ..add(_record(id: 'r1', note: 'original'))
        ..add(_record(id: 'r1', note: 'forged'));
      final b = Ledger()..add(_record(id: 'r2'));

      final mergedAB = a.merge(b);
      final mergedBA = b.merge(a);

      // Same winning record for the conflicted id, on both sides.
      expect(
        mergedAB.records.firstWhere((r) => r.id == 'r1').note,
        mergedBA.records.firstWhere((r) => r.id == 'r1').note,
      );
      expect(mergedAB.conflicts.length, mergedBA.conflicts.length);
      expect(
        mergedAB.records.map((r) => r.id).toSet(),
        mergedBA.records.map((r) => r.id).toSet(),
      );
    });

    test('merging an empty ledger changes nothing', () {
      final a = Ledger()..add(_record(id: 'r1'));

      final merged = a.merge(Ledger());

      expect(merged.records.map((r) => r.id).toSet(), {'r1'});
    });
  });

  group('Ledger.versionVector', () {
    test('empty ledger has an empty vector', () {
      expect(Ledger().versionVector(), <String, int>{});
    });

    test('counts contiguous seqs per author, stopping at a gap', () {
      final ledger = Ledger()
        ..add(_record(id: 'a1', author: 'alice', seq: 1))
        ..add(_record(id: 'a2', author: 'alice', seq: 2))
        ..add(_record(id: 'a3', author: 'alice', seq: 3))
        // gap: alice seq 4 missing
        ..add(_record(id: 'a5', author: 'alice', seq: 5))
        ..add(_record(id: 'b1', author: 'bob', seq: 1));

      expect(ledger.versionVector(), {'alice': 3, 'bob': 1});
    });

    test('an author with no seq 1 record has no entry', () {
      final ledger = Ledger()..add(_record(id: 'a2', author: 'alice', seq: 2));

      expect(ledger.versionVector(), <String, int>{});
    });

    test('is unaffected by the order records were added', () {
      final inOrder = Ledger()
        ..add(_record(id: 'a1', author: 'alice', seq: 1))
        ..add(_record(id: 'a2', author: 'alice', seq: 2));
      final reversed = Ledger()
        ..add(_record(id: 'a2', author: 'alice', seq: 2))
        ..add(_record(id: 'a1', author: 'alice', seq: 1));

      expect(inOrder.versionVector(), reversed.versionVector());
    });
  });
}
