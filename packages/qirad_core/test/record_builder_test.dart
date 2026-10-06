import 'package:qirad_core/qirad_core.dart';
import 'package:test/test.dart';

import 'support/partnership_fixture.dart';
import 'support/test_ids.dart';

Record _unsignedInvest(
  String author,
  String partnership,
  Iterable<Record> ledger,
) => buildRecord(
  ledger: ledger,
  author: author,
  partnership: partnership,
  id: testId('invest-${ledger.length}'),
  type: 'invest',
  body: {'amount': 1000},
  time: '2026-10-06T10:00:00Z',
);

void main() {
  group('buildRecord (spec 3, 7.1)', () {
    test(
      'the first record of a new chain has seq 1 and 64 zeros as prevHash',
      () {
        final record = buildRecord(
          ledger: const [],
          author: 'author-key',
          partnership: 'partnership-1',
          id: testId('first'),
          type: 'partnership_create',
          body: const {},
          time: '2026-10-06T10:00:00Z',
        );

        expect(record.seq, 1);
        expect(record.prevHash, '0' * 64);
        expect(record.sig, '');
      },
    );

    test('a built record is accepted by the validator once signed', () async {
      final (validator, investor, _, partnershipId) = await setUpPartnership();

      // The investor's own chain on this phone: the create at seq 1.
      final unsigned = _unsignedInvest(
        investor.key,
        partnershipId,
        validator.usableRecords,
      );
      final signed = await signRecord(unsigned, investor.keyPair);

      expect(
        await validator.receiveText(canonicalJson(signed.toJson())),
        ReceiveOutcome.accepted,
      );
    });

    test(
      'the next record continues the chain: seq and prevHash follow the last one',
      () async {
        final (validator, investor, _, partnershipId) =
            await setUpPartnership();
        final first = await signRecord(
          _unsignedInvest(investor.key, partnershipId, validator.usableRecords),
          investor.keyPair,
        );
        await validator.receiveText(canonicalJson(first.toJson()));

        final next = _unsignedInvest(
          investor.key,
          partnershipId,
          validator.usableRecords,
        );

        // The create is seq 1 and the invest is seq 2, so the next one is seq 3.
        expect(next.seq, 3);
        expect(next.prevHash, recordHash(first.toJson()));
      },
    );

    test('other partners records do not change my next seq', () async {
      final (validator, investor, manager, partnershipId) =
          await setUpPartnership();
      final managerRecord = await manager.next(
        partnership: partnershipId,
        type: 'sale',
        body: {'amount': 100},
      );
      await validator.receiveText(canonicalJson(managerRecord.toJson()));

      // Only the create is mine, so the next one is seq 2.
      final next = _unsignedInvest(
        investor.key,
        partnershipId,
        validator.usableRecords,
      );
      expect(next.seq, 2);
    });

    test('a gap in my own chain is refused rather than built on', () async {
      final (validator, investor, _, partnershipId) = await setUpPartnership();
      final create = validator.usableRecords.single;
      // Seq 3 with no seq 2: the chain has a hole, so no next record is safe.
      final gapped = Record(
        v: 1,
        id: testId('gapped'),
        partnership: partnershipId,
        author: investor.key,
        seq: 3,
        prevHash: recordHash(create.toJson()),
        type: 'invest',
        body: const {'amount': 100},
        refersTo: null,
        note: '',
        time: '2026-10-06T10:00:00Z',
        sig: '',
      );

      expect(
        () => buildRecord(
          ledger: [create, gapped],
          author: investor.key,
          partnership: partnershipId,
          id: testId('next'),
          type: 'invest',
          body: const {'amount': 100},
          time: '2026-10-06T10:00:00Z',
        ),
        throwsA(isA<ChainGapException>()),
      );
    });

    test('two records of mine with the same seq are refused', () async {
      final (validator, investor, _, partnershipId) = await setUpPartnership();
      final create = validator.usableRecords.single; // my seq 1
      final invest = await investor.next(
        partnership: partnershipId,
        type: 'invest',
        body: const {'amount': 100},
      ); // my seq 2
      // A second record at seq 2 is an equivocation, so it is refused.
      final twin = Record(
        v: 1,
        id: testId('twin'),
        partnership: partnershipId,
        author: investor.key,
        seq: invest.seq,
        prevHash: invest.prevHash,
        type: 'invest',
        body: const {'amount': 200},
        refersTo: null,
        note: '',
        time: '2026-10-06T10:00:00Z',
        sig: '',
      );

      expect(
        () => buildRecord(
          ledger: [create, invest, twin],
          author: investor.key,
          partnership: partnershipId,
          id: testId('next'),
          type: 'invest',
          body: const {'amount': 100},
          time: '2026-10-06T10:00:00Z',
        ),
        throwsA(isA<ChainGapException>()),
      );
    });
  });
}
