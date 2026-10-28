import 'dart:convert';

import 'package:qirad_core/qirad_core.dart';

/// A minimal in-memory stand-in for the relay's sync endpoint (spec 7.1/7.3),
/// used so RQ1 can reconstruct a device's ledger through the real sync
/// decision logic (`firstMissingSeqs`, version vectors) instead of injecting
/// records directly into the other device's validator, which is what
/// `workload_generator.dart`'s own internal delivery queues do for speed.
///
/// Mirrors the relevant parts of `apps/mobile/test/support/fake_relay.dart`:
/// exact-text storage, hash de-duplication, and a gap-aware version vector.
/// Deliberately leaves out registration, tokens and HTTP — RQ1 does not need
/// them, and they already have their own Phase 5/6 tests.
class RelaySim {
  /// Texts by position (`author|seq`). More than one entry at a position is
  /// a conflict (two different records equivocating at the same seq).
  final Map<String, List<String>> _positions = {};
  final Set<String> _hashes = {};

  /// Stores [text] as if a device had just uploaded it. Exact duplicates
  /// (same hash) are dropped, exactly like the real relay (spec 6.1 step 6).
  void upload(String text) {
    final json = jsonDecode(text) as Map<String, dynamic>;
    if (!_hashes.add(recordHash(json))) return;
    final key = '${json['author']}|${json['seq']}';
    _positions.putIfAbsent(key, () => []).add(text);
  }

  /// One sync call (spec 7.3 step 3–4): stores [uploads], then returns every
  /// record newer than [clientVector], any conflicting position in full, and
  /// the relay's own gap-aware vector.
  RelaySyncReply sync({
    required Map<String, int> clientVector,
    required List<String> uploads,
  }) {
    for (final text in uploads) {
      upload(text);
    }
    final records = <String>[];
    final conflicts = <String>[];
    for (final key in _sortedKeys()) {
      final versions = _positions[key]!;
      final author = key.split('|').first;
      final seq = int.parse(key.split('|').last);
      if (seq > (clientVector[author] ?? 0)) records.add(versions.first);
      if (versions.length > 1) conflicts.addAll(versions);
    }
    return RelaySyncReply(
      records: records,
      conflicts: conflicts,
      vector: vector(),
    );
  }

  /// Gap-aware, as in spec 7.1: the highest seq reached with nothing missing
  /// below it, per author.
  Map<String, int> vector() {
    final seqsByAuthor = <String, Set<int>>{};
    for (final key in _positions.keys) {
      final author = key.split('|').first;
      final seq = int.parse(key.split('|').last);
      seqsByAuthor.putIfAbsent(author, () => {}).add(seq);
    }
    final result = <String, int>{};
    seqsByAuthor.forEach((author, seqs) {
      var top = 0;
      while (seqs.contains(top + 1)) {
        top++;
      }
      if (top > 0) result[author] = top;
    });
    return result;
  }

  List<String> _sortedKeys() {
    final keys = _positions.keys.toList()
      ..sort((a, b) {
        final authorA = a.split('|').first;
        final authorB = b.split('|').first;
        if (authorA != authorB) return authorA.compareTo(authorB);
        return int.parse(
          a.split('|').last,
        ).compareTo(int.parse(b.split('|').last));
      });
    return keys;
  }
}

/// What one [RelaySim.sync] call returns: records the client was behind on,
/// any conflicting positions, and the relay's own vector after the call.
class RelaySyncReply {
  const RelaySyncReply({
    required this.records,
    required this.conflicts,
    required this.vector,
  });

  final List<String> records;
  final List<String> conflicts;
  final Map<String, int> vector;
}
