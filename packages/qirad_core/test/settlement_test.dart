import 'package:qirad_core/qirad_core.dart';
import 'package:test/test.dart';

import 'support/partnership_fixture.dart';

Effectiveness _effective(Validator validator) => computeEffective(
  validator.usableRecords,
  partnershipKeys: validator.partnershipKeys!,
);

Decision _decisionFor(Validator validator, Record target) => decideApprovals(
  validator.usableRecords,
  partnershipKeys: validator.partnershipKeys!,
).singleWhere((d) => d.target.id == target.id);

Future<void> _receive(Validator validator, Iterable<Record> records) async {
  for (final record in records) {
    await validator.receiveText(canonicalJson(record.toJson()));
  }
}

void main() {
  group('settlement authorship (spec 6.7)', () {
    test(
      'a manager settlement is effective once the investor approves it',
      () async {
        final (validator, investor, manager, partnershipId) =
            await setUpPartnership();
        final settlement = await manager.next(
          partnership: partnershipId,
          type: settlementType,
          body: {
            'cut': {investor.key: 0, manager.key: 0},
          },
        );
        await _receive(validator, [settlement]);
        expect(
          _effective(validator).isEffective(settlement),
          isFalse,
          reason: 'not approved yet',
        );

        final approve = await investor.next(
          partnership: partnershipId,
          type: 'approve',
          refersTo: settlement.id,
        );
        await _receive(validator, [approve]);

        expect(_effective(validator).isEffective(settlement), isTrue);
      },
    );

    test(
      'an investor-authored settlement is never effective, even when the manager approves it',
      () async {
        final (validator, investor, manager, partnershipId) =
            await setUpPartnership();
        final settlement = await investor.next(
          partnership: partnershipId,
          type: settlementType,
          body: {
            'cut': {investor.key: 0, manager.key: 0},
          },
        );
        final approve = await manager.next(
          partnership: partnershipId,
          type: 'approve',
          refersTo: settlement.id,
        );
        await _receive(validator, [settlement, approve]);

        // The manager's approval is valid, so the decision is active. The record
        // is still not effective, because only the manager may propose (6.7).
        expect(
          _decisionFor(validator, settlement).status,
          DecisionStatus.active,
        );
        expect(_effective(validator).isEffective(settlement), isFalse);
      },
    );

    test('the manager cannot approve their own settlement', () async {
      final (validator, investor, manager, partnershipId) =
          await setUpPartnership();
      final settlement = await manager.next(
        partnership: partnershipId,
        type: settlementType,
        body: {
          'cut': {investor.key: 0, manager.key: 0},
        },
      );
      final selfApprove = await manager.next(
        partnership: partnershipId,
        type: 'approve',
        refersTo: settlement.id,
      );
      await _receive(validator, [settlement, selfApprove]);

      final decision = _decisionFor(validator, settlement);
      expect(decision.status, DecisionStatus.pending);
      expect(decision.firstResponse, isNull);
      expect(decision.ignoredResponses, isEmpty);
      expect(_effective(validator).isEffective(settlement), isFalse);
    });
  });

  group('ordering rule (spec 6.7)', () {
    test(
      'approving S2 before S1 is invalid, and S2 waits for a new approval',
      () async {
        final (validator, investor, manager, partnershipId) =
            await setUpPartnership();
        final s1 = await manager.next(
          partnership: partnershipId,
          type: settlementType,
          body: {
            'cut': {investor.key: 0, manager.key: 0},
          },
        );
        final s2 = await manager.next(
          partnership: partnershipId,
          type: settlementType,
          body: {
            'cut': {investor.key: 0, manager.key: 0},
          },
        );
        // Investor seq 2 answers S2 while S1 is still unanswered.
        final approveS2Early = await investor.next(
          partnership: partnershipId,
          type: 'approve',
          refersTo: s2.id,
        );
        final approveS1 = await investor.next(
          partnership: partnershipId,
          type: 'approve',
          refersTo: s1.id,
        );
        await _receive(validator, [s1, s2, approveS2Early, approveS1]);

        final decision = _decisionFor(validator, s2);
        expect(decision.status, DecisionStatus.pending);
        expect(decision.invalidResponses.map((r) => r.id), [approveS2Early.id]);

        final effective = _effective(validator);
        expect(effective.isEffective(s1), isTrue);
        expect(effective.isEffective(s2), isFalse);
        expect(
          effective.invalidResponses.containsKey(approveS2Early.id),
          isTrue,
        );

        // A fresh approval of S2, made after S1, is valid.
        final approveS2Again = await investor.next(
          partnership: partnershipId,
          type: 'approve',
          refersTo: s2.id,
        );
        await _receive(validator, [approveS2Again]);

        final after = _effective(validator);
        expect(after.isEffective(s2), isTrue);
        expect(
          after.invalidResponses.containsKey(approveS2Early.id),
          isTrue,
          reason: 'the invalid response stays on record as evidence',
        );
      },
    );

    test('the same records give the same result in any arrival order', () async {
      final (validator, investor, manager, partnershipId) =
          await setUpPartnership();
      final s1 = await manager.next(
        partnership: partnershipId,
        type: settlementType,
        body: {
          'cut': {investor.key: 0, manager.key: 0},
        },
      );
      final s2 = await manager.next(
        partnership: partnershipId,
        type: settlementType,
        body: {
          'cut': {investor.key: 0, manager.key: 0},
        },
      );
      final approveS2Early = await investor.next(
        partnership: partnershipId,
        type: 'approve',
        refersTo: s2.id,
      );
      final approveS1 = await investor.next(
        partnership: partnershipId,
        type: 'approve',
        refersTo: s1.id,
      );
      final approveS2Again = await investor.next(
        partnership: partnershipId,
        type: 'approve',
        refersTo: s2.id,
      );
      final all = [s1, s2, approveS2Early, approveS1, approveS2Again];
      await _receive(validator, all);
      final inOrder = _effective(validator);

      // A second device gets the create first, then the rest in reverse order.
      final create = validator.usableRecords.singleWhere(
        (r) => r.type == 'partnership_create',
      );
      final other = Validator.unpinnedForTesting();
      await _receive(other, [create]);
      await _receive(other, all.reversed);
      final reversed = _effective(other);

      expect(reversed.effectiveIds, inOrder.effectiveIds);
      expect(reversed.invalidResponses.keys, inOrder.invalidResponses.keys);
    });
  });

  group('cut shape (spec 6.7, step 4a rules)', () {
    test(
      'a malformed cut is never effective, while a well-formed one is',
      () async {
        final (validator, investor, manager, partnershipId) =
            await setUpPartnership();

        // Each cut is built just before its record is made, because the last
        // case needs the manager's next seq. A plain map would read it too early.
        final badCuts = <Map<String, dynamic> Function()>[
          () => {investor.key: 0}, // one key only
          () => {
            investor.key: 0,
            manager.key: 0,
            'someone-else': 0,
          }, // three keys
          () => {investor.key: 0, 'someone-else': 0}, // manager key missing
          () => {investor.key: -1, manager.key: 0}, // negative value
          () => {investor.key: '5', manager.key: 0}, // not an integer
          () => {
            investor.key: 0,
            manager.key: manager.seq + 1,
          }, // manager value not below own seq
        ];

        final bad = <Record>[];
        for (final cut in badCuts) {
          bad.add(
            await manager.next(
              partnership: partnershipId,
              type: settlementType,
              body: {'cut': cut()},
            ),
          );
        }
        final badWithRef = await manager.next(
          partnership: partnershipId,
          type: settlementType,
          body: {
            'cut': {investor.key: 0, manager.key: 0},
          },
          refersTo: partnershipId,
        );
        bad.add(badWithRef);

        final control = await manager.next(
          partnership: partnershipId,
          type: settlementType,
          body: {
            'cut': {investor.key: 0, manager.key: 0},
          },
        );
        final approveControl = await investor.next(
          partnership: partnershipId,
          type: 'approve',
          refersTo: control.id,
        );
        await _receive(validator, [...bad, control, approveControl]);

        final effective = _effective(validator);
        for (final record in bad) {
          expect(
            effective.isEffective(record),
            isFalse,
            reason: 'seq ${record.seq}',
          );
        }
        expect(effective.isEffective(control), isTrue);
      },
    );
  });
}
