import 'effective.dart';
import 'ratio.dart';
import 'record.dart';

/// The profit split that applies on [date] (a `YYYY-MM-DD` string), spec 6.6.
///
/// Start with the ratio of the effective `partnership_create`. Then apply each
/// effective `ratio_proposal` whose `effectiveFrom` is on or before [date]. The
/// latest one wins. Returns `null` if no partnership is effective yet.
Ratio? activeRatio(
  Iterable<Record> usable, {
  required Effectiveness effectiveness,
  required String date,
}) {
  if (!isIsoDate(date)) {
    throw ArgumentError.value(date, 'date', 'must be YYYY-MM-DD');
  }

  final effective = usable.where(effectiveness.isEffective).toList();

  // A ledger holds one partnership, so at most one create can be usable
  // (decision 2026-10-03, one partnership per ledger). Two would mean the
  // validator is broken, so fail loudly instead of guessing.
  final creates = effective
      .where((r) => r.type == 'partnership_create')
      .toList();
  if (creates.length > 1) {
    throw StateError(
      'ledger holds ${creates.length} partnership_create records',
    );
  }
  if (creates.isEmpty) return null;

  var ratio = ratioOf(creates.single);

  // Sorting by (effectiveFrom, author, seq) makes a tie on the same date
  // resolve the same way everywhere. The last matching proposal is the latest.
  final proposals = effective.where((r) => r.type == 'ratio_proposal').toList()
    ..sort((a, b) {
      final byDate = _effectiveFrom(a).compareTo(_effectiveFrom(b));
      return byDate != 0 ? byDate : _byAuthorThenSeq(a, b);
    });
  for (final proposal in proposals) {
    // ISO dates sort as text in the same order as calendar dates.
    if (_effectiveFrom(proposal).compareTo(date) <= 0) {
      ratio = ratioOf(proposal);
    }
  }
  return ratio;
}

String _effectiveFrom(Record record) => record.body['effectiveFrom'] as String;

int _byAuthorThenSeq(Record a, Record b) {
  final byAuthor = a.author.compareTo(b.author);
  return byAuthor != 0 ? byAuthor : a.seq.compareTo(b.seq);
}
