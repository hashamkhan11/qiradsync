import 'ledger.dart';
import 'record.dart';
import 'record_hash.dart';
import 'signing.dart';

/// What happened when a raw incoming record was run through [Validator.receive],
/// spec section 6.1.
enum ReceiveOutcome {
  /// Step 1 failed: a required field is missing or the wrong type. Not stored.
  rejectedSchema,

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
  final Ledger ledger = Ledger();

  Set<String>? _partnershipKeys;

  final Map<String, Map<int, Record>> _pending = {};
  final Map<String, Map<int, Record>> _acceptedBySeq = {};
  final Map<String, Record> _chainHead = {};
  final Map<String, int> _equivocatingFromSeq = {};
  final Set<String> _chainInvalidIds = {};

  /// Records buffered because an earlier `seq` from the same author hasn't
  /// arrived yet.
  Iterable<Record> get pendingRecords =>
      _pending.values.expand((bySeq) => bySeq.values);

  /// `{ author -> lowest seq at which that author was caught equivocating }`.
  Map<String, int> get equivocatingFromSeq => Map.unmodifiable(_equivocatingFromSeq);

  /// Ids of records that reached the front of the chain but had the wrong
  /// `prevHash` — stored as evidence, never advanced the chain.
  Set<String> get chainInvalidIds => Set.unmodifiable(_chainInvalidIds);

  /// The two public keys allowed to author records for this partnership,
  /// once known (learned from the accepted `partnership_create`). `null`
  /// before that — the bootstrap case in spec section 5.
  Set<String>? get partnershipKeys =>
      _partnershipKeys == null ? null : Set.unmodifiable(_partnershipKeys!);

  Future<ReceiveOutcome> receive(Map<String, dynamic> json) async {
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
      }
    }

    return outcome;
  }

  bool _passesMembership(Record record) {
    if (_partnershipKeys == null) {
      return record.type == 'partnership_create';
    }
    return _partnershipKeys!.contains(record.author);
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
    if (addOutcome == AddOutcome.duplicateIgnored) return ReceiveOutcome.duplicateIgnored;
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
    _equivocatingFromSeq[author] =
        currentFlagSeq == null ? seq : (seq < currentFlagSeq ? seq : currentFlagSeq);

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
