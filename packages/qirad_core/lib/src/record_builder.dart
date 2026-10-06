import 'record.dart';
import 'record_hash.dart';

/// Thrown when this phone's own chain in the ledger is broken: a missing seq, or
/// two records with the same seq. Building on a broken chain would fork it, so
/// the builder refuses instead (spec 7.1, chains have no gaps).
class ChainGapException implements Exception {
  final String message;

  const ChainGapException(this.message);

  @override
  String toString() => 'ChainGapException: $message';
}

/// Builds the next unsigned record of [author] in [partnership] (spec 3).
///
/// The caller passes every stored record it has, not only the usable ones. The
/// builder reads the author's own chain from them, so an own record that was
/// refused for another reason must still be in [ledger]. Leaving it out would
/// make the next record reuse its seq, which is a fork.
///
/// Why the caller cannot pass `seq` or `prevHash`: they come from the ledger
/// alone, so two callers can never disagree about them.
///
/// The `time` is passed in, because core never reads the clock (hard rule 3).
/// It is for display only.
///
/// Returns an unsigned record (`sig` is empty). Sign it with `signRecord`.
Record buildRecord({
  required Iterable<Record> ledger,
  required String author,
  required String partnership,
  required String id,
  required String type,
  required Map<String, dynamic> body,
  required String time,
  String? refersTo,
  String note = '',
}) {
  final mine =
      ledger
          .where((r) => r.author == author && r.partnership == partnership)
          .toList()
        ..sort((a, b) => a.seq.compareTo(b.seq));

  // The own chain must be exactly seq 1, 2, 3, ... with no gap and no repeat.
  for (var i = 0; i < mine.length; i++) {
    if (mine[i].seq != i + 1) {
      throw ChainGapException(
        'own chain has seq ${mine[i].seq} where ${i + 1} was expected',
      );
    }
  }

  // The first record has no earlier record, so its prevHash is 64 zeros.
  final prevHash = mine.isEmpty ? '0' * 64 : recordHash(mine.last.toJson());

  return Record(
    v: 1,
    id: id,
    partnership: partnership,
    author: author,
    seq: mine.length + 1,
    prevHash: prevHash,
    type: type,
    body: body,
    refersTo: refersTo,
    note: note,
    time: time,
    sig: '',
  );
}
