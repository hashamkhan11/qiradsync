import 'package:qirad_core/qirad_core.dart';
import 'package:test/test.dart';

/// Signs a growing chain of records for one author, tracking `seq` and
/// `prevHash` the way a real device would.
class _Author {
  final Ed25519KeyPair keyPair;
  int seq = 0;
  String prevHash = '0' * 64;
  int _counter = 0;

  _Author(this.keyPair);

  String get key => keyPair.publicKeyBase64Url;

  Future<Record> next({
    required String partnership,
    required String type,
    Map<String, dynamic> body = const {},
    String note = '',
  }) async {
    seq += 1;
    _counter += 1;
    final unsigned = Record(
      v: 1,
      id: '${key.substring(0, 8)}-rec-$_counter',
      partnership: partnership,
      author: key,
      seq: seq,
      prevHash: prevHash,
      type: type,
      body: body,
      refersTo: null,
      note: note,
      time: '2026-10-02T10:00:00Z',
      sig: '',
    );
    final signed = await signRecord(unsigned, keyPair);
    prevHash = recordHash(signed.toJson());
    return signed;
  }
}

/// A validator with a partnership already bootstrapped: the investor's
/// `partnership_create` (seq 1) has been accepted, so `partnershipKeys`
/// is known and both partners can author further records.
Future<(Validator, _Author, _Author, String)> _setUp() async {
  final investor = _Author(await generateEd25519KeyPair());
  final manager = _Author(await generateEd25519KeyPair());
  const partnershipId = 'partnership-1';
  final validator = Validator();

  final create = await investor.next(
    partnership: partnershipId,
    type: 'partnership_create',
    body: {'investor': investor.key, 'manager': manager.key},
  );
  expect(await validator.receive(create.toJson()), ReceiveOutcome.accepted);

  return (validator, investor, manager, partnershipId);
}

void main() {
  group('step 1 — schema', () {
    test('a record missing required fields is rejected, not stored', () async {
      final validator = Validator();
      final outcome = await validator.receive({'v': 1, 'id': 'x'});

      expect(outcome, ReceiveOutcome.rejectedSchema);
      expect(validator.ledger.records, isEmpty);
    });
  });

  group('step 2 — signature', () {
    test('a field tampered with after signing is rejected', () async {
      final (validator, investor, _, partnershipId) = await _setUp();
      final record = await investor.next(partnership: partnershipId, type: 'note');
      final tampered = record.copyWith(note: 'tampered after signing');

      expect(await validator.receive(tampered.toJson()), ReceiveOutcome.rejectedSignature);
    });
  });

  group('step 3 — membership', () {
    test('the bootstrap partnership_create fixes the two allowed keys', () async {
      final (validator, investor, manager, _) = await _setUp();

      expect(validator.partnershipKeys, {investor.key, manager.key});
    });

    test('a record from a key outside the partnership is rejected', () async {
      final (validator, _, _, partnershipId) = await _setUp();
      final outsider = _Author(await generateEd25519KeyPair());
      final rogue = await outsider.next(partnership: partnershipId, type: 'note');

      expect(await validator.receive(rogue.toJson()), ReceiveOutcome.rejectedMembership);
    });
  });

  group('step 4 — hash chain', () {
    test('wrong prevHash is detected and flagged, not accepted', () async {
      final (validator, investor, _, partnershipId) = await _setUp();
      final good = await investor.next(partnership: partnershipId, type: 'note');

      investor.prevHash = 'f' * 64; // corrupt the chain before signing the next one
      final broken = await investor.next(partnership: partnershipId, type: 'note');

      expect(await validator.receive(good.toJson()), ReceiveOutcome.accepted);
      expect(await validator.receive(broken.toJson()), ReceiveOutcome.chainInvalid);
      expect(validator.chainInvalidIds, contains(broken.id));
    });

    test('a gap is buffered, then released as a cascade once filled', () async {
      final (validator, investor, _, partnershipId) = await _setUp();
      final r2 = await investor.next(partnership: partnershipId, type: 'note');
      final r3 = await investor.next(partnership: partnershipId, type: 'note');
      final r4 = await investor.next(partnership: partnershipId, type: 'note');

      expect(await validator.receive(r4.toJson()), ReceiveOutcome.pending);
      expect(await validator.receive(r3.toJson()), ReceiveOutcome.pending);
      expect(await validator.receive(r2.toJson()), ReceiveOutcome.accepted);

      expect(validator.pendingRecords, isEmpty);
      expect(
        validator.ledger.records.map((r) => r.id),
        containsAll([r2.id, r3.id, r4.id]),
      );
    });
  });

  group('step 5 — equivocation', () {
    test('two different records at the same seq are flagged, both kept as evidence', () async {
      final (validator, investor, _, partnershipId) = await _setUp();
      final honest = await investor.next(
        partnership: partnershipId,
        type: 'note',
        body: {'n': 1},
      );

      investor.seq -= 1; // same author tries to reuse seq 2 for a different record
      final forged = await investor.next(
        partnership: partnershipId,
        type: 'note',
        body: {'n': 2},
      );

      expect(await validator.receive(honest.toJson()), ReceiveOutcome.accepted);
      expect(await validator.receive(forged.toJson()), ReceiveOutcome.equivocating);

      expect(validator.equivocatingFromSeq[investor.key], 2);
      expect(
        validator.ledger.records.map((r) => r.id),
        containsAll([honest.id, forged.id]),
      );
    });
  });

  group('step 6 — duplicate', () {
    test('re-receiving the same record is harmless', () async {
      final (validator, investor, _, partnershipId) = await _setUp();
      final record = await investor.next(partnership: partnershipId, type: 'note');

      expect(await validator.receive(record.toJson()), ReceiveOutcome.accepted);
      expect(await validator.receive(record.toJson()), ReceiveOutcome.duplicateIgnored);
    });
  });
}
