import 'record.dart';
import 'record_hash.dart';

/// What happened when a record was added to a [Ledger].
enum AddOutcome {
  /// The record's `id` was new; it is now stored.
  added,

  /// The record's `id` was already stored, with identical content
  /// (same hash). Harmless — the record is already there, nothing changes.
  duplicateIgnored,

  /// The record's `id` was already stored, but with *different* content
  /// (a different hash). The new record is rejected and not stored, but
  /// kept as evidence in [Ledger.conflicts] (spec section 6.1 step 6).
  idConflict,
}

/// A grow-only set (G-Set) of records, keyed by `id`.
///
/// This is the CRDT storage structure: records are never edited or removed
/// (hard rule), so "merge" is just set union. This class does not check
/// signatures or hash chains — that is Phase 3's validation pipeline. It
/// only answers "is this `id` new, a duplicate, or a conflict?"
class Ledger {
  final Map<String, Record> _byId = {};
  final List<Record> _conflicts = [];

  /// All stored records, in no particular order. Callers that need a
  /// deterministic order (calculations, version vectors) must sort
  /// explicitly, per spec section 6.2.
  Iterable<Record> get records => _byId.values;

  /// Records rejected because their `id` collided with an existing record
  /// of different content. Kept as evidence, per spec section 6.1 step 6.
  Iterable<Record> get conflicts => _conflicts;

  AddOutcome add(Record record) {
    final existing = _byId[record.id];
    if (existing == null) {
      _byId[record.id] = record;
      return AddOutcome.added;
    }
    if (recordHash(existing.toJson()) == recordHash(record.toJson())) {
      return AddOutcome.duplicateIgnored;
    }
    _conflicts.add(record);
    return AddOutcome.idConflict;
  }

  /// Combines this ledger with [other], as CRDT set union (spec section 1).
  ///
  /// Every record either ledger has ever seen — stored or conflicted — is
  /// replayed into a fresh [Ledger], sorted by hash rather than by arrival
  /// order. Sorting by a fixed, content-based key (not "which ledger saw it
  /// first") is what makes `merge(a, b)` and `merge(b, a)` always produce
  /// the exact same result, even in the pathological case where two
  /// different records share an `id` (hard rule: deterministic regardless
  /// of order).
  Ledger merge(Ledger other) {
    final all = [...records, ...conflicts, ...other.records, ...other.conflicts]
      ..sort((a, b) => recordHash(a.toJson()).compareTo(recordHash(b.toJson())));
    final merged = Ledger();
    for (final record in all) {
      merged.add(record);
    }
    return merged;
  }

  /// `{ author -> highest seq held without gaps }`, spec section 7.1.
  ///
  /// Counts up from 1 for each author's stored `seq` numbers, stopping at
  /// the first missing one. An author with no `seq = 1` record contributes
  /// no entry at all.
  Map<String, int> versionVector() {
    final seqsByAuthor = <String, Set<int>>{};
    for (final record in records) {
      seqsByAuthor.putIfAbsent(record.author, () => {}).add(record.seq);
    }

    final vector = <String, int>{};
    for (final entry in seqsByAuthor.entries) {
      var highest = 0;
      while (entry.value.contains(highest + 1)) {
        highest++;
      }
      if (highest > 0) {
        vector[entry.key] = highest;
      }
    }
    return vector;
  }
}
