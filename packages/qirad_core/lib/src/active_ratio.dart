import 'effective.dart';
import 'ratio.dart';
import 'record.dart';

/// The ratio in force now, and the start date the partners agreed to (spec 6.6).
class ActiveRatio {
  final Ratio ratio;

  /// The `effectiveFrom` of the proposal that set [ratio], shown as text so
  /// people can read it. It is `null` for the starting ratio from the create.
  /// Nothing is calculated from this date.
  final String? agreedStart;

  const ActiveRatio({required this.ratio, required this.agreedStart});

  @override
  String toString() => agreedStart == null
      ? '$ratio (from the start)'
      : '$ratio (agreed to start $agreedStart)';
}

/// The ratio in force, spec 6.6. No clock is used.
///
/// The last effective `ratio_proposal` in `(effectiveFrom, author, seq)` order
/// is the active one. The sort uses the agreed date as text, so a tie resolves
/// the same way on every phone. If no proposal is effective, the ratio from the
/// approved `partnership_create` is active. Returns `null` if the partnership
/// is not approved yet.
ActiveRatio? activeRatio(
  Iterable<Record> usable, {
  required Effectiveness effectiveness,
}) {
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

  final proposals = effective.where((r) => r.type == 'ratio_proposal').toList()
    ..sort((a, b) {
      final byDate = _effectiveFrom(a).compareTo(_effectiveFrom(b));
      return byDate != 0 ? byDate : _byAuthorThenSeq(a, b);
    });
  // Effectiveness already requires a valid ratio and an ISO date, so the
  // last proposal always has a ratio.
  if (proposals.isNotEmpty) {
    final latest = proposals.last;
    return ActiveRatio(
      ratio: ratioOf(latest)!,
      agreedStart: _effectiveFrom(latest),
    );
  }

  final starting = ratioOf(creates.single);
  if (starting == null) return null;
  return ActiveRatio(ratio: starting, agreedStart: null);
}

String _effectiveFrom(Record record) => record.body['effectiveFrom'] as String;

int _byAuthorThenSeq(Record a, Record b) {
  final byAuthor = a.author.compareTo(b.author);
  return byAuthor != 0 ? byAuthor : a.seq.compareTo(b.seq);
}
