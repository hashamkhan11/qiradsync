import 'package:qirad_core/qirad_core.dart';
import 'package:test/test.dart';
import 'support/test_ids.dart';

Record _record({required String id, String note = ''}) {
  return Record(
    v: 1,
    id: id,
    partnership: testId('p1'),
    author: 'author1',
    seq: 1,
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
  group('Ledger.add', () {
    test('a new id is added', () {
      final ledger = Ledger();

      final outcome = ledger.add(_record(id: testId('r1')));

      expect(outcome, AddOutcome.added);
      expect(ledger.records, [predicate<Record>((r) => r.id == testId('r1'))]);
    });

    test('the same record added twice is a harmless duplicate', () {
      final ledger = Ledger();
      final record = _record(id: testId('r1'));

      ledger.add(record);
      final outcome = ledger.add(record);

      expect(outcome, AddOutcome.duplicateIgnored);
      expect(ledger.records.length, 1);
    });

    test('same id, different content is rejected and kept as a conflict', () {
      final ledger = Ledger();

      ledger.add(_record(id: testId('r1'), note: 'original'));
      final outcome = ledger.add(_record(id: testId('r1'), note: 'forged'));

      expect(outcome, AddOutcome.idConflict);
      expect(ledger.records.length, 1);
      expect(ledger.records.single.note, 'original');
      expect(ledger.conflicts.length, 1);
      expect(ledger.conflicts.single.note, 'forged');
    });

    test('different ids are both stored', () {
      final ledger = Ledger();

      ledger.add(_record(id: testId('r1')));
      ledger.add(_record(id: testId('r2')));

      expect(ledger.records.length, 2);
    });
  });
}
