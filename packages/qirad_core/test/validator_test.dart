import 'package:qirad_core/qirad_core.dart';
import 'package:test/test.dart';

import 'support/partnership_fixture.dart';

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
      final (validator, investor, _, partnershipId) = await setUpPartnership();
      final record = await investor.next(partnership: partnershipId, type: 'note');
      final tampered = record.copyWith(note: 'tampered after signing');

      expect(await validator.receive(tampered.toJson()), ReceiveOutcome.rejectedSignature);
    });
  });

  group('step 3 — membership', () {
    test('the bootstrap partnership_create fixes the two allowed keys', () async {
      final (validator, investor, manager, _) = await setUpPartnership();

      expect(validator.partnershipKeys, {investor.key, manager.key});
    });

    test('a record from a key outside the partnership is rejected', () async {
      final (validator, _, _, partnershipId) = await setUpPartnership();
      final outsider = ChainAuthor(await generateEd25519KeyPair());
      final rogue = await outsider.next(partnership: partnershipId, type: 'note');

      expect(await validator.receive(rogue.toJson()), ReceiveOutcome.rejectedMembership);
    });
  });

  group('step 4 — hash chain', () {
    test('wrong prevHash is detected and flagged, not accepted', () async {
      final (validator, investor, _, partnershipId) = await setUpPartnership();
      final good = await investor.next(partnership: partnershipId, type: 'note');

      investor.prevHash = 'f' * 64; // corrupt the chain before signing the next one
      final broken = await investor.next(partnership: partnershipId, type: 'note');

      expect(await validator.receive(good.toJson()), ReceiveOutcome.accepted);
      expect(await validator.receive(broken.toJson()), ReceiveOutcome.chainInvalid);
      expect(validator.chainInvalidIds, contains(broken.id));
    });

    test('a gap is buffered, then released as a cascade once filled', () async {
      final (validator, investor, _, partnershipId) = await setUpPartnership();
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
      final (validator, investor, _, partnershipId) = await setUpPartnership();
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
      final (validator, investor, _, partnershipId) = await setUpPartnership();
      final record = await investor.next(partnership: partnershipId, type: 'note');

      expect(await validator.receive(record.toJson()), ReceiveOutcome.accepted);
      expect(await validator.receive(record.toJson()), ReceiveOutcome.duplicateIgnored);
    });
  });
}
