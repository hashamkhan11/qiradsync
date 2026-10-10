import 'package:qirad_core/qirad_core.dart';
import 'package:test/test.dart';

import 'support/cut_helper.dart';
import 'support/partnership_fixture.dart';
import 'support/test_ids.dart';

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

/// A settlement the validator's own membership rule now refuses outright
/// (spec section 5: only the manager may author one) — a real device can
/// never get this record stored, since `receiveText` rejects it at step 3.
/// Added straight to the ledger, bypassing `receive()` entirely, so the
/// tests below can still check the business-layer rule (`settlementCut`'s
/// own author check, and the ordering rule) as defense in depth, the same
/// "redundant guard stays tested" pattern as the 2026-10-06 mutation check.
Future<Record> _handBuiltSettlement(
  ChainAuthor author, {
  required String partnership,
  required Map<String, dynamic> body,
  required String name,
}) async {
  final unsigned = Record(
    v: 1,
    id: testId(name),
    partnership: partnership,
    author: author.key,
    seq: 500,
    prevHash: '0' * 64,
    type: settlementType,
    body: body,
    refersTo: null,
    note: '',
    time: '2026-10-05T09:00:00Z',
    sig: '',
  );
  return signRecord(unsigned, author.keyPair);
}

Record _createOf(Validator validator) =>
    validator.usableRecords.singleWhere((r) => r.type == 'partnership_create');

void main() {
  group('settlement authorship (spec 6.7)', () {
    test(
      'a manager settlement is effective once the investor approves it',
      () async {
        final (validator, investor, manager, partnershipId) =
            await setUpPartnership();
        final create = _createOf(validator);
        // A cut up to the create is held: the investor has that record.
        final settlement = await manager.next(
          partnership: partnershipId,
          type: settlementType,
          body: {'cut': cutUpTo(investor, manager, upToInvestor: create)},
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
        final create = _createOf(validator);
        final settlement = await _handBuiltSettlement(
          investor,
          partnership: partnershipId,
          body: {'cut': cutUpTo(investor, manager, upToInvestor: create)},
          name: 'investor-authored-settlement-1',
        );
        validator.ledger.add(settlement);
        final approve = await manager.next(
          partnership: partnershipId,
          type: 'approve',
          refersTo: settlement.id,
        );
        await _receive(validator, [approve]);

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
      final create = _createOf(validator);
      final settlement = await manager.next(
        partnership: partnershipId,
        type: settlementType,
        body: {'cut': cutUpTo(investor, manager, upToInvestor: create)},
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
        final create = _createOf(validator);
        final s1 = await manager.next(
          partnership: partnershipId,
          type: settlementType,
          body: {'cut': cutUpTo(investor, manager, upToInvestor: create)},
        );
        final s2 = await manager.next(
          partnership: partnershipId,
          type: settlementType,
          body: {
            'cut': cutUpTo(
              investor,
              manager,
              upToInvestor: create,
              upToManager: s1,
            ),
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
        final create = _createOf(validator);
        final s1 = await manager.next(
          partnership: partnershipId,
          type: settlementType,
          body: {'cut': cutUpTo(investor, manager, upToInvestor: create)},
        );
        final s2 = await manager.next(
          partnership: partnershipId,
          type: settlementType,
          body: {
            'cut': cutUpTo(
              investor,
              manager,
              upToInvestor: create,
              upToManager: s1,
            ),
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

        // Each other device gets the create and the manager's approve of it
        // first, then the rest in a different order. Chains buffer gaps, so
        // every order must reach the same result.
        final approveCreate = validator.usableRecords.singleWhere(
          (r) => r.type == 'approve' && r.refersTo == create.id,
        );
        final orders = <List<int>>[
          [4, 3, 2, 1, 0], // reversed
          [2, 4, 0, 3, 1],
          [3, 0, 4, 1, 2],
          [1, 2, 3, 4, 0],
        ];
        for (final order in orders) {
          final other = Validator.unpinnedForTesting();
          await _receive(other, [create, approveCreate]);
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
        final create = _createOf(validator);
        final s1 = await manager.next(
          partnership: partnershipId,
          type: settlementType,
          body: {'cut': cutUpTo(investor, manager, upToInvestor: create)},
        );
        // The investor writes a settlement of their own. It is not a proposal,
        // so it must not count in the ordering rule. Its cut covers nothing
        // from either side, on purpose.
        final investorOwn = await _handBuiltSettlement(
          investor,
          partnership: partnershipId,
          body: {
            'cut': {investor.key: 0, manager.key: 0},
          },
          name: 'investor-authored-settlement-2',
        );
        validator.ledger.add(investorOwn);
        final approveS1 = await investor.next(
          partnership: partnershipId,
          type: 'approve',
          refersTo: s1.id,
        );
        await _receive(validator, [s1, approveS1]);

        expect(_effective(validator).isEffective(s1), isTrue);
        expect(_effective(validator).isEffective(investorOwn), isFalse);
      },
    );

    test(
      'a malformed settlement does not block the next proposal',
      () async {
        final (validator, investor, manager, partnershipId) =
            await setUpPartnership();
        final create = _createOf(validator);
        // Three keys is not a valid cut shape (spec 6.7, step 4a), so this
        // settlement is never effective. That is a business-layer rule, not
        // a schema one, so the record is still accepted and stored (spec
        // section 5 only requires `cut` to be a Map at the schema step).
        final malformed = await manager.next(
          partnership: partnershipId,
          type: settlementType,
          body: {
            'cut': {
              ...cutUpTo(investor, manager, upToInvestor: create),
              'someone-else': 0,
            },
          },
        );
        final s2 = await manager.next(
          partnership: partnershipId,
          type: settlementType,
          body: {
            'cut': cutUpTo(
              investor,
              manager,
              upToInvestor: create,
              upToManager: malformed,
            ),
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
        final create = _createOf(validator);

        // Each cut is built just before its record is made, because the last
        // case needs the manager's next seq. A plain map would read it too early.
        final badCuts = <Map<String, dynamic> Function()>[
          () => {investor.key: create.seq}, // one key only
          () => {
            investor.key: create.seq,
            manager.key: 0,
            'someone-else': 0,
          }, // three keys
          () => {investor.key: create.seq, 'someone-else': 0}, // manager key missing
          () => {investor.key: -1, manager.key: 0}, // negative value
          () => {investor.key: '5', manager.key: 0}, // not an integer
          () => {
            investor.key: create.seq,
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
        // A settlement with a refersTo is a schema-level malformation now
        // (spec section 3: refersTo must be null for this type), covered by
        // the table-driven schema tests. This group stays focused on cut
        // shape, a business-layer rule (spec 6.7, step 4a).

        final control = await manager.next(
          partnership: partnershipId,
          type: settlementType,
          body: {'cut': cutUpTo(investor, manager, upToInvestor: create)},
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
      final create = _createOf(validator);
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
          'cut': cutUpTo(
            investor,
            manager,
            upToInvestor: create,
            upToManager: empty,
          ),
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
      final create = _createOf(validator);
      final invest = await investor.next(
        partnership: partnershipId,
        type: 'invest',
        body: {'amount': 100},
      );
      final s1 = await manager.next(
        partnership: partnershipId,
        type: settlementType,
        body: {'cut': cutUpTo(investor, manager, upToInvestor: invest)},
      );
      final approveS1 = await investor.next(
        partnership: partnershipId,
        type: 'approve',
        refersTo: s1.id,
      );
      // S2 is written after S1, but its investor value is lower than S1's:
      // it only reaches the create, not the invest S1 already covered.
      final s2 = await manager.next(
        partnership: partnershipId,
        type: settlementType,
        body: {
          'cut': cutUpTo(
            investor,
            manager,
            upToInvestor: create,
            upToManager: s1,
          ),
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

    test('a second cut identical to the first is invalid', () async {
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
        body: {'cut': cutUpTo(investor, manager, upToInvestor: invest)},
      );
      final approveS1 = await investor.next(
        partnership: partnershipId,
        type: 'approve',
        refersTo: s1.id,
      );
      // S2 covers exactly what S1 covered, so it adds nothing. Its cut must
      // strictly exceed the previous one somewhere, or it is invalid.
      final s2 = await manager.next(
        partnership: partnershipId,
        type: settlementType,
        body: {'cut': cutUpTo(investor, manager, upToInvestor: invest)},
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
      expect(s2Status.reason, 'covers nothing new');
    });

    test('a rejected S1 does not block S2', () async {
      final (validator, investor, manager, partnershipId) =
          await setUpPartnership();
      final create = _createOf(validator);
      final s1 = await manager.next(
        partnership: partnershipId,
        type: settlementType,
        body: {'cut': cutUpTo(investor, manager, upToInvestor: create)},
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
          'cut': cutUpTo(
            investor,
            manager,
            upToInvestor: create,
            upToManager: s1,
          ),
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
        final create = _createOf(validator);
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
        // S1's cut reaches the expense but stops at the create on the
        // investor's side, so it does not reach the budget the expense
        // refers to.
        final s1 = await manager.next(
          partnership: partnershipId,
          type: settlementType,
          body: {
            'cut': cutUpTo(
              investor,
              manager,
              upToInvestor: create,
              upToManager: expense,
            ),
          },
        );
        final approveS1 = await investor.next(
          partnership: partnershipId,
          type: 'approve',
          refersTo: s1.id,
        );
        await _receive(validator, [budget, expense, s1, approveS1]);

        // Guard: the scenario only tests what it means to if the expense is
        // inside S1's cut and the budget it refers to is outside it.
        final s1Cut = settlementCut(s1, proposedParties(validator.usableRecords)!)!;
        expect(
          expense.seq,
          lessThanOrEqualTo(s1Cut[manager.key]!),
          reason: 'the expense is inside the cut',
        );
        expect(
          budget.seq,
          greaterThan(s1Cut[investor.key]!),
          reason: 'the budget is outside the cut',
        );

        final s1Status = _statusOf(validator, s1);
        expect(s1Status.state, SettlementState.invalid);
        expect(s1Status.reason, 'refers to a record outside the cut');

        // S2 covers the budget, so its closure check passes.
        final s2 = await manager.next(
          partnership: partnershipId,
          type: settlementType,
          body: {
            'cut': cutUpTo(
              investor,
              manager,
              upToInvestor: budget,
              upToManager: s1,
            ),
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
        final create = _createOf(validator);
        // The investor's chain does not reach seq 5 yet. The manager names it
        // anyway.
        final s1 = await manager.next(
          partnership: partnershipId,
          type: settlementType,
          body: {
            'cut': {investor.key: create.seq + 4, manager.key: 0},
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
            'cut': cutUpTo(
              investor,
              manager,
              upToInvestor: create,
              upToManager: s1,
            ),
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
      // The approve that will answer this settlement is the investor's next
      // record after `invest`, so its own seq is `invest.seq + 1`. A cut
      // value equal to that is not below it, so the approve is invalid.
      final s1 = await manager.next(
        partnership: partnershipId,
        type: settlementType,
        body: {
          'cut': {investor.key: invest.seq + 1, manager.key: 0},
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
      final create = _createOf(validator);
      final s1 = await manager.next(
        partnership: partnershipId,
        type: settlementType,
        body: {'cut': cutUpTo(investor, manager, upToInvestor: create)},
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
