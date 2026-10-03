import 'dart:convert';

import 'package:meta/meta.dart';

import 'canonical_json.dart';
import 'ledger.dart';
import 'record.dart';
import 'record_hash.dart';
import 'signing.dart';

/// What happened when a raw incoming record was run through [Validator.receiveText],
/// spec section 6.1.
enum ReceiveOutcome {
  /// Step 1 failed: a required field is missing or the wrong type, a key is
  /// unknown, or the record type is not one of spec section 5's. Not stored.
  rejectedSchema,

  /// Step 1 failed: the text is valid JSON but not in canonical form (extra
  /// whitespace, wrong key order, duplicate keys, `[]` for `{}`, and so on).
  /// Not stored. Checked on the text, because duplicate keys vanish once parsed.
  rejectedNotCanonical,

  /// Step 2 failed: `sig` does not verify against `author`. Not stored.
  rejectedSignature,

  /// Step 3 failed: `author` is not one of the partnership's two keys
  /// (and this is not the bootstrap `partnership_create`). Not stored.
  rejectedMembership,

  /// Step 4: this author's `seq - 1` record has not been seen yet. Buffered
  /// until the gap is filled, then released (possibly a whole chain of them).
  pending,

  /// Step 4 failed: the author's `seq - 1` record is known, but `prevHash`
  /// does not match it. Stored as evidence; does not advance the chain.
  chainInvalid,

  /// Step 5: this author already has a different record at this `seq`
  /// (either accepted earlier, or sitting in the pending buffer). Both are
  /// kept as evidence; the author is flagged from this `seq` onward.
  equivocating,

  /// Passed every check and is new. Stored and usable.
  accepted,

  /// Same `id`, identical content already stored. Harmless re-delivery.
  duplicateIgnored,

  /// Same `id`, different content already stored. Rejected, kept as evidence.
  idConflict,
}

/// Parses raw JSON into a [Record], checking spec section 3's shape
/// (step 1 of section 6.1). Returns `null` if anything required is missing
/// or the wrong type — the record-level schema only; type-specific `body`
/// contents (e.g. "amounts are positive integers") depend on the record
/// type table in spec section 5, which is validated once that business
/// logic exists (Phase 4), not here.
Record? parseRecordSchema(Map<String, dynamic> json) {
  try {
    // Unknown top-level keys are refused, so nothing can ride along unsigned
    // in a way one device keeps and another drops.
    if (json.keys.any((key) => !_recordFields.contains(key))) return null;

    if (json['v'] != 1) return null;

    final id = json['id'];
    final partnership = json['partnership'];
    final author = json['author'];
    final seq = json['seq'];
    final prevHash = json['prevHash'];
    final type = json['type'];
    final body = json['body'];
    final refersTo = json['refersTo'];
    final note = json['note'];
    final time = json['time'];
    final sig = json['sig'];

    if (id is! String || id.isEmpty) return null;
    if (partnership is! String || partnership.isEmpty) return null;
    if (author is! String || author.isEmpty) return null;
    if (seq is! int || seq < 1) return null;
    if (prevHash is! String || prevHash.length != 64) return null;
    if (type is! String || type.isEmpty) return null;
    if (body is! Map) return null;
    if (refersTo != null && refersTo is! String) return null;
    if (note is! String || note.length > 500) return null;
    if (time is! String) return null;
    if (sig is! String) return null;

    // A partnership is named by its own create record, so the create's
    // `partnership` must be its own `id` (spec section 3).
    if (type == 'partnership_create' && partnership != id) return null;

    // The body keys are fixed per type (spec section 5). A type not in the
    // table has no allowed keys, so it is refused outright.
    final allowedBodyKeys = _bodyFields[type];
    if (allowedBodyKeys == null) return null;
    if (body.keys.any((key) => !allowedBodyKeys.contains(key))) return null;
    final ratio = body['ratio'];
    if (ratio != null && !_hasExactlyRatioKeys(ratio)) return null;

    return Record(
      v: 1,
      id: id,
      partnership: partnership,
      author: author,
      seq: seq,
      prevHash: prevHash,
      type: type,
      body: Map<String, dynamic>.from(body),
      refersTo: refersTo as String?,
      note: note,
      time: time,
      sig: sig,
    );
  } catch (_) {
    return null;
  }
}

/// The fields of a record, spec section 3. Any other top-level key is invalid.
const _recordFields = {
  'v',
  'id',
  'partnership',
  'author',
  'seq',
  'prevHash',
  'type',
  'body',
  'refersTo',
  'note',
  'time',
  'sig',
};

/// The keys a record type's `body` may have, spec section 5. Empty for the
/// types that carry no data (`reversal`, `approve`, `reject`).
const _bodyFields = <String, Set<String>>{
  'partnership_create': {'investor', 'manager', 'ratio', 'currency'},
  'invest': {'amount'},
  'sale': {'amount'},
  'budget_proposal': {'grantee', 'amount'},
  'expense': {'amount', 'receiptHash'},
  'withdraw_request': {'amount', 'kind'},
  'ratio_proposal': {'ratio', 'effectiveFrom'},
  'reversal': <String>{},
  'approve': <String>{},
  'reject': <String>{},
};

/// A `ratio` is exactly `{investor, manager}` (spec section 5). Its values
/// are checked later, in ratioOf, where a bad sum just means "no ratio".
bool _hasExactlyRatioKeys(Object? ratio) {
  return ratio is Map &&
      ratio.length == 2 &&
      ratio.containsKey('investor') &&
      ratio.containsKey('manager');
}

/// Runs raw incoming records through spec section 6.1's full pipeline:
/// schema, signature, membership, hash-chain (with a pending buffer for
/// gaps), and equivocation detection. Duplicate/conflict handling (step 6)
/// is delegated to the wrapped [Ledger].
///
/// What counts as "usable for calculations" once a record is stored here —
/// e.g. excluding an equivocating author's later records, per section 6.3 —
/// is deliberately left to Phase 4, where that depends on approval rules
/// that don't exist yet. This class only classifies and stores evidence
/// correctly; [equivocatingFromSeq] and [chainInvalidIds] are the markers
/// that computation will read.
class Validator {
  /// [pinnedInvestorKey] and [pinnedManagerKey] come from the join code
  /// (spec section 2.1). The first `partnership_create` is accepted only if it
  /// names these keys. Both are required: without pins, any valid create
  /// would be accepted, which is the forged-create attack (spec 2.1).
  Validator({
    required String pinnedInvestorKey,
    required String pinnedManagerKey,
  }) : this._(pinnedInvestorKey, pinnedManagerKey);

  /// A validator with no pins. Any valid `partnership_create` is accepted.
  /// Only the core's own rule tests may use this; the app must always pin.
  @visibleForTesting
  Validator.unpinnedForTesting() : this._(null, null);

  Validator._(this.pinnedInvestorKey, this.pinnedManagerKey);

  final String? pinnedInvestorKey;
  final String? pinnedManagerKey;

  final Ledger ledger = Ledger();

  Set<String>? _partnershipKeys;

  /// The id of the one partnership this ledger holds, learned from the first
  /// accepted `partnership_create`. A ledger never holds a second partnership:
  /// records naming any other partnership are rejected (spec 6.1, step 3).
  String? _partnershipId;

  final Map<String, Map<int, Record>> _pending = {};
  final Map<String, Map<int, Record>> _acceptedBySeq = {};
  final Map<String, Record> _chainHead = {};
  final Map<String, int> _equivocatingFromSeq = {};
  final Set<String> _chainInvalidIds = {};

  /// Records buffered because an earlier `seq` from the same author hasn't
  /// arrived yet.
  Iterable<Record> get pendingRecords =>
      _pending.values.expand((bySeq) => bySeq.values);

  /// Stored records that may feed calculations: not chain-invalid, and not
  /// from an equivocating author's `seq` onward (spec section 6.1 steps 4–5).
  /// Pending records are never in the ledger, so they are excluded already.
  Iterable<Record> get usableRecords => ledger.records.where((record) {
    if (_chainInvalidIds.contains(record.id)) return false;
    final equivocatingFrom = _equivocatingFromSeq[record.author];
    return equivocatingFrom == null || record.seq < equivocatingFrom;
  });

  /// `{ author -> lowest seq at which that author was caught equivocating }`.
  Map<String, int> get equivocatingFromSeq =>
      Map.unmodifiable(_equivocatingFromSeq);

  /// Ids of records that reached the front of the chain but had the wrong
  /// `prevHash` — stored as evidence, never advanced the chain.
  Set<String> get chainInvalidIds => Set.unmodifiable(_chainInvalidIds);

  /// The two public keys allowed to author records for this partnership,
  /// once known (learned from the accepted `partnership_create`). `null`
  /// before that — the bootstrap case in spec section 5.
  Set<String>? get partnershipKeys =>
      _partnershipKeys == null ? null : Set.unmodifiable(_partnershipKeys!);

  /// Receives a record as the exact text that arrived over the network.
  ///
  /// The text must already be canonical: parse it, encode it again, and
  /// accept only if the bytes match. This refuses extra whitespace, wrong key
  /// order, duplicate keys (`jsonDecode` silently keeps the last one), and
  /// `[]` where `{}` belongs. Every device then stores the same bytes, so the
  /// hash and signature mean the same thing everywhere (spec 6.1, step 1).
  Future<ReceiveOutcome> receiveText(String text) async {
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      return ReceiveOutcome.rejectedSchema;
    }
    if (decoded is! Map<String, dynamic>) return ReceiveOutcome.rejectedSchema;

    final String reencoded;
    try {
      reencoded = canonicalJson(decoded);
    } on ArgumentError {
      // For example a float such as 1.5, which canonical JSON never allows.
      return ReceiveOutcome.rejectedNotCanonical;
    }
    if (reencoded != text) return ReceiveOutcome.rejectedNotCanonical;

    return _receiveParsed(decoded);
  }

  /// The steps after the canonical-form check. Private on purpose: the only
  /// way in is [receiveText], so no path can skip the byte check. A record
  /// the app builds itself goes through `canonicalJson(record.toJson())` first.
  Future<ReceiveOutcome> _receiveParsed(Map<String, dynamic> json) async {
    final record = parseRecordSchema(json);
    if (record == null) return ReceiveOutcome.rejectedSchema;

    if (!await verifyRecord(record)) return ReceiveOutcome.rejectedSignature;

    if (!_passesMembership(record)) return ReceiveOutcome.rejectedMembership;

    final outcome = _acceptIntoChain(record);

    if (outcome == ReceiveOutcome.accepted &&
        record.type == 'partnership_create' &&
        _partnershipKeys == null) {
      final investor = record.body['investor'];
      final manager = record.body['manager'];
      if (investor is String && manager is String) {
        _partnershipKeys = {investor, manager};
        _partnershipId = record.partnership;
      }
    }

    return outcome;
  }

  bool _passesMembership(Record record) {
    if (_partnershipKeys == null) {
      return record.type == 'partnership_create' && _matchesPins(record);
    }
    // Only one partnership per ledger. A second create (or any record for
    // another partnership) is rejected here, so it is never stored.
    if (record.partnership != _partnershipId) return false;
    return _partnershipKeys!.contains(record.author);
  }

  /// A create must name the pinned keys, and be signed by the pinned
  /// investor. This stops a forged create from being accepted first. The
  /// relay can send any signed record, so the signature alone proves only
  /// that its author made it, not that it is the real partnership.
  bool _matchesPins(Record record) {
    final investor = pinnedInvestorKey;
    if (investor != null) {
      if (record.author != investor) return false;
      if (record.body['investor'] != investor) return false;
    }
    final manager = pinnedManagerKey;
    if (manager != null && record.body['manager'] != manager) return false;
    return true;
  }

  ReceiveOutcome _acceptIntoChain(Record record) {
    final author = record.author;
    final seq = record.seq;

    final acceptedAtSeq = _acceptedBySeq[author]?[seq];
    if (acceptedAtSeq != null) {
      if (recordHash(acceptedAtSeq.toJson()) == recordHash(record.toJson())) {
        ledger.add(record);
        return ReceiveOutcome.duplicateIgnored;
      }
      return _flagEquivocation(record, acceptedAtSeq);
    }

    final pendingAtSeq = _pending[author]?[seq];
    if (pendingAtSeq != null) {
      if (recordHash(pendingAtSeq.toJson()) == recordHash(record.toJson())) {
        return ReceiveOutcome.duplicateIgnored;
      }
      return _flagEquivocation(record, pendingAtSeq);
    }

    final head = _chainHead[author];
    final expectedSeq = (head?.seq ?? 0) + 1;

    if (seq > expectedSeq) {
      _pending.putIfAbsent(author, () => {})[seq] = record;
      return ReceiveOutcome.pending;
    }

    final expectedPrevHash = seq == 1 ? '0' * 64 : recordHash(head!.toJson());
    if (record.prevHash != expectedPrevHash) {
      ledger.add(record);
      _chainInvalidIds.add(record.id);
      return ReceiveOutcome.chainInvalid;
    }

    final addOutcome = ledger.add(record);
    if (addOutcome == AddOutcome.duplicateIgnored) {
      return ReceiveOutcome.duplicateIgnored;
    }
    if (addOutcome == AddOutcome.idConflict) return ReceiveOutcome.idConflict;

    _chainHead[author] = record;
    _acceptedBySeq.putIfAbsent(author, () => {})[seq] = record;
    _releasePending(author);
    return ReceiveOutcome.accepted;
  }

  ReceiveOutcome _flagEquivocation(Record incoming, Record existing) {
    final author = incoming.author;
    final seq = incoming.seq;

    final currentFlagSeq = _equivocatingFromSeq[author];
    _equivocatingFromSeq[author] = currentFlagSeq == null
        ? seq
        : (seq < currentFlagSeq ? seq : currentFlagSeq);

    ledger.add(existing);
    ledger.add(incoming);
    _pending[author]?.remove(seq);
    return ReceiveOutcome.equivocating;
  }

  void _releasePending(String author) {
    while (true) {
      final head = _chainHead[author];
      final nextSeq = (head?.seq ?? 0) + 1;
      final candidate = _pending[author]?.remove(nextSeq);
      if (candidate == null) return;
      if (_acceptIntoChain(candidate) != ReceiveOutcome.accepted) return;
    }
  }
}
