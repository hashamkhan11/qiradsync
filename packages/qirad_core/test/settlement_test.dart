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

SettlementStatus _statusOf(Validator validator, Record proposal) => _effective(
  validator,
).settlements.singleWhere((s) => s.record.id == proposal.id);

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
        // Investor seq 1 is the create, so a cut of 1 from the investor is held.
        final settlement = await manager.next(
          partnership: partnershipId,
          type: settlementType,
          body: {
            'cut': {investor.key: 1, manager.key: 0},
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
            'cut': {investor.key: 1, manager.key: 0},
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
          'cut': {investor.key: 1, manager.key: 0},
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
            'cut': {investor.key: 1, manager.key: 0},
          },
        );
        final s2 = await manager.next(
          partnership: partnershipId,
          type: settlementType,
          body: {
            'cut': {investor.key: 1, manager.key: 1},
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

        // The early answer is invalid, so it never counts. The decision is the
        // later valid answer, not the early one.
        expect(
          _decisionFor(validator, s2).firstResponse?.id,
          approveS2Again.id,
        );
        final after = _effective(validator);
        expect(after.isEffective(s2), isTrue);
        expect(
          after.invalidResponses.containsKey(approveS2Early.id),
          isTrue,
          reason: 'the invalid response stays on record as evidence',
        );
      },
    );

    test(
      'the same records give the same result in any arrival order',
      () async {
        final (validator, investor, manager, partnershipId) =
            await setUpPartnership();
        final s1 = await manager.next(
          partnership: partnershipId,
          type: settlementType,
          body: {
            'cut': {investor.key: 1, manager.key: 0},
          },
        );
        final s2 = await manager.next(
          partnership: partnershipId,
          type: settlementType,
          body: {
            'cut': {investor.key: 1, manager.key: 1},
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
        final inOrderFirst = _decisionFor(validator, s2).firstResponse?.id;

        // Each other device gets the create first, then the rest in a different
        // order. Chains buffer gaps, so every order must reach the same result.
        final create = validator.usableRecords.singleWhere(
          (r) => r.type == 'partnership_create',
        );
        final orders = <List<int>>[
          [4, 3, 2, 1, 0], // reversed
          [2, 4, 0, 3, 1],
          [3, 0, 4, 1, 2],
          [1, 2, 3, 4, 0],
        ];
        for (final order in orders) {
          final other = Validator.unpinnedForTesting();
          await _receive(other, [create]);
          await _receive(other, [for (final i in order) all[i]]);
          final replay = _effective(other);

          expect(replay.effectiveIds, inOrder.effectiveIds, reason: '$order');
          expect(
            replay.invalidResponses.keys,
            inOrder.invalidResponses.keys,
            reason: '$order',
          );
          expect(
            _decisionFor(other, s2).firstResponse?.id,
            inOrderFirst,
            reason: '$order',
          );
        }
      },
    );

    test(
      'an investor-authored settlement does not block the investor\'s answers',
      () async {
        final (validator, investor, manager, partnershipId) =
            await setUpPartnership();
        final s1 = await manager.next(
          partnership: partnershipId,
          type: settlementType,
          body: {
            'cut': {investor.key: 1, manager.key: 0},
          },
        );
        // The investor writes a settlement of their own. It is not a proposal,
        // so it must not count in the ordering rule.
        final investorOwn = await investor.next(
          partnership: partnershipId,
          type: settlementType,
          body: {
            'cut': {investor.key: 0, manager.key: 0},
          },
        );
        final approveS1 = await investor.next(
          partnership: partnershipId,
          type: 'approve',
          refersTo: s1.id,
        );
        await _receive(validator, [s1, investorOwn, approveS1]);

        expect(_effective(validator).isEffective(s1), isTrue);
        expect(_effective(validator).isEffective(investorOwn), isFalse);
      },
    );

    test(
      'a malformed settlement with a refersTo does not block the next proposal',
      () async {
        final (validator, investor, manager, partnershipId) =
            await setUpPartnership();
        final malformed = await manager.next(
          partnership: partnershipId,
          type: settlementType,
          body: {
            'cut': {investor.key: 1, manager.key: 0},
          },
          refersTo: partnershipId,
        );
        final s2 = await manager.next(
          partnership: partnershipId,
          type: settlementType,
          body: {
            'cut': {investor.key: 1, manager.key: 1},
          },
        );
        final approveS2 = await investor.next(
          partnership: partnershipId,
          type: 'approve',
          refersTo: s2.id,
        );
        await _receive(validator, [malformed, s2, approveS2]);

        expect(_effective(validator).isEffective(malformed), isFalse);
        expect(_effective(validator).isEffective(s2), isTrue);
      },
    );
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
          () => {investor.key: 1}, // one key only
          () => {
            investor.key: 1,
            manager.key: 0,
            'someone-else': 0,
          }, // three keys
          () => {investor.key: 1, 'someone-else': 0}, // manager key missing
          () => {investor.key: -1, manager.key: 0}, // negative value
          () => {investor.key: '5', manager.key: 0}, // not an integer
          () => {
            investor.key: 1,
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
            'cut': {investor.key: 1, manager.key: 0},
          },
          refersTo: partnershipId,
        );
        bad.add(badWithRef);

        final control = await manager.next(
          partnership: partnershipId,
          type: settlementType,
          body: {
            'cut': {investor.key: 1, manager.key: 0},
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

  group('closed, dominating and non-empty cuts (spec 6.7, step 4b)', () {
    test('an empty cut is invalid and does not block the next one', () async {
      final (validator, investor, manager, partnershipId) =
          await setUpPartnership();
      final empty = await manager.next(
        partnership: partnershipId,
        type: settlementType,
        body: {
          'cut': {investor.key: 0, manager.key: 0},
        },
      );
      final approveEmpty = await investor.next(
        partnership: partnershipId,
        type: 'approve',
        refersTo: empty.id,
      );
      final next = await manager.next(
        partnership: partnershipId,
        type: settlementType,
        body: {
          'cut': {investor.key: 1, manager.key: 1},
        },
      );
      final approveNext = await investor.next(
        partnership: partnershipId,
        type: 'approve',
        refersTo: next.id,
      );
      await _receive(validator, [empty, approveEmpty, next, approveNext]);

      final emptyStatus = _statusOf(validator, empty);
      expect(emptyStatus.state, SettlementState.invalid);
      expect(emptyStatus.reason, 'covers nothing new');
      expect(_statusOf(validator, next).state, SettlementState.effective);
    });

    test('a cut that does not cover the previous cut is invalid', () async {
      final (validator, investor, manager, partnershipId) =
          await setUpPartnership();
      final invest = await investor.next(
        partnership: partnershipId,
        type: 'invest',
        body: {'amount': 100},
      );
      final s1 = await manager.next(
        partnership: partnershipId,
        type: settlementType,
        body: {
          'cut': {investor.key: 2, manager.key: 0},
        },
      );
      final approveS1 = await investor.next(
        partnership: partnershipId,
        type: 'approve',
        refersTo: s1.id,
      );
      // S2 is written after S1, but its investor value is lower than S1's.
      final s2 = await manager.next(
        partnership: partnershipId,
        type: settlementType,
        body: {
          'cut': {investor.key: 1, manager.key: 1},
        },
      );
      final approveS2 = await investor.next(
        partnership: partnershipId,
        type: 'approve',
        refersTo: s2.id,
      );
      await _receive(validator, [invest, s1, approveS1, s2, approveS2]);

      expect(_statusOf(validator, s1).state, SettlementState.effective);
      final s2Status = _statusOf(validator, s2);
      expect(s2Status.state, SettlementState.invalid);
      expect(s2Status.reason, 'does not cover the previous cut');
    });

    test('a rejected S1 does not block S2', () async {
      final (validator, investor, manager, partnershipId) =
          await setUpPartnership();
      final s1 = await manager.next(
        partnership: partnershipId,
        type: settlementType,
        body: {
          'cut': {investor.key: 1, manager.key: 0},
        },
      );
      final rejectS1 = await investor.next(
        partnership: partnershipId,
        type: 'reject',
        refersTo: s1.id,
      );
      final s2 = await manager.next(
        partnership: partnershipId,
        type: settlementType,
        body: {
          'cut': {investor.key: 1, manager.key: 1},
        },
      );
      final approveS2 = await investor.next(
        partnership: partnershipId,
        type: 'approve',
        refersTo: s2.id,
      );
      await _receive(validator, [s1, rejectS1, s2, approveS2]);

      expect(_statusOf(validator, s1).state, SettlementState.rejected);
      expect(_statusOf(validator, s2).state, SettlementState.effective);
    });

    test(
      'an approved S1 that is not closed becomes permanently invalid, and S2 can then be effective',
      () async {
        final (validator, investor, manager, partnershipId) =
            await setUpPartnership();
        // The budget is investor seq 2. The expense is manager seq 1 and points
        // at the budget, but S1's cut stops at investor seq 1. So the expense
        // refers to a record outside the cut.
        final budget = await investor.next(
          partnership: partnershipId,
          type: 'budget_proposal',
          body: {'grantee': manager.key, 'amount': 1000},
        );
        final expense = await manager.next(
          partnership: partnershipId,
          type: 'expense',
          refersTo: budget.id,
          body: {'amount': 300},
        );
        final s1 = await manager.next(
          partnership: partnershipId,
          type: settlementType,
          body: {
            'cut': {investor.key: 1, manager.key: 1},
          },
        );
        final approveS1 = await investor.next(
          partnership: partnershipId,
          type: 'approve',
          refersTo: s1.id,
        );
        await _receive(validator, [budget, expense, s1, approveS1]);

        final s1Status = _statusOf(validator, s1);
        expect(s1Status.state, SettlementState.invalid);
        expect(s1Status.reason, 'refers to a record outside the cut');

        // S2 covers the budget, so its closure check passes.
        final s2 = await manager.next(
          partnership: partnershipId,
          type: settlementType,
          body: {
            'cut': {investor.key: 2, manager.key: 2},
          },
        );
        final approveS2 = await investor.next(
          partnership: partnershipId,
          type: 'approve',
          refersTo: s2.id,
        );
        await _receive(validator, [s2, approveS2]);

        expect(_statusOf(validator, s2).state, SettlementState.effective);
        expect(_effective(validator).isEffective(s1), isFalse);
      },
    );
  });

  group('approve rule: an approve must come after its cut (spec 6.7)', () {
    test(
      'an approve whose cut names investor records that do not exist is invalid, and a reject lets S2 proceed',
      () async {
        final (validator, investor, manager, partnershipId) =
            await setUpPartnership();
        // Investor seq 5 does not exist yet. The manager names it anyway.
        final s1 = await manager.next(
          partnership: partnershipId,
          type: settlementType,
          body: {
            'cut': {investor.key: 5, manager.key: 0},
          },
        );
        final approveS1 = await investor.next(
          partnership: partnershipId,
          type: 'approve',
          refersTo: s1.id,
        );
        await _receive(validator, [s1, approveS1]);

        // The approve is invalid, so S1 waits. It is kept as evidence.
        expect(_statusOf(validator, s1).state, SettlementState.waiting);
        expect(
          _effective(validator).invalidResponses[approveS1.id],
          contains('cannot have seen'),
        );

        // The investor rejects S1. Rejected counts as done, so S2 can proceed.
        final rejectS1 = await investor.next(
          partnership: partnershipId,
          type: 'reject',
          refersTo: s1.id,
        );
        final s2 = await manager.next(
          partnership: partnershipId,
          type: settlementType,
          body: {
            'cut': {investor.key: 1, manager.key: 1},
          },
        );
        final approveS2 = await investor.next(
          partnership: partnershipId,
          type: 'approve',
          refersTo: s2.id,
        );
        await _receive(validator, [rejectS1, s2, approveS2]);

        expect(_statusOf(validator, s1).state, SettlementState.rejected);
        expect(_statusOf(validator, s2).state, SettlementState.effective);
      },
    );

    test('an approve whose cut value equals its own seq is invalid', () async {
      final (validator, investor, manager, partnershipId) =
          await setUpPartnership();
      final invest = await investor.next(
        partnership: partnershipId,
        type: 'invest',
        body: {'amount': 100},
      );
      // The invest is investor seq 2, so this approve is investor seq 3. The cut
      // value 3 is equal to the approve's seq, so it is not below it.
      final s1 = await manager.next(
        partnership: partnershipId,
        type: settlementType,
        body: {
          'cut': {investor.key: 3, manager.key: 0},
        },
      );
      final approveAtEqual = await investor.next(
        partnership: partnershipId,
        type: 'approve',
        refersTo: s1.id,
      );
      await _receive(validator, [invest, s1, approveAtEqual]);

      expect(_statusOf(validator, s1).state, SettlementState.waiting);
      expect(_decisionFor(validator, s1).invalidResponses.map((r) => r.id), [
        approveAtEqual.id,
      ]);
    });

    test('a valid approve still guarantees the cut is held', () async {
      final (validator, investor, manager, partnershipId) =
          await setUpPartnership();
      final s1 = await manager.next(
        partnership: partnershipId,
        type: settlementType,
        body: {
          'cut': {investor.key: 1, manager.key: 0},
        },
      );
      final approveS1 = await investor.next(
        partnership: partnershipId,
        type: 'approve',
        refersTo: s1.id,
      );
      await _receive(validator, [s1, approveS1]);

      final status = _statusOf(validator, s1);
      expect(status.state, SettlementState.effective);
      expect(cutIsHeld(validator.usableRecords, status.cut), isTrue);
    });
  });
}
