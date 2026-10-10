import 'package:qirad_core/qirad_core.dart';
import 'package:test/test.dart';

import 'support/cut_helper.dart';
import 'support/partnership_fixture.dart';
import 'support/test_ids.dart';

Future<void> _receive(Validator validator, Iterable<Record> records) async {
  for (final record in records) {
    await validator.receiveText(canonicalJson(record.toJson()));
  }
}

RecordStatus _statusOf(Validator validator, Record record) => recordStatuses(
  validator.ledger.records,
  usable: validator.usableRecords,
  chainInvalidIds: validator.chainInvalidIds,
  equivocatingFromSeq: validator.equivocatingFromSeq,
  partnershipKeys: validator.partnershipKeys!,
)[record.id]!;

void main() {
  group('recordStatuses (spec sections 5, 6.1, 6.3, 6.4, 6.7)', () {
    test('an effective invest is effective', () async {
      final (validator, investor, _, partnershipId) = await setUpPartnership();
      final invest = await investor.next(
        partnership: partnershipId,
        type: 'invest',
        body: const {'amount': 10000},
      );
      await _receive(validator, [invest]);

      expect(_statusOf(validator, invest), RecordStatus.effective);
    });

    test('the create itself waits for approval before the manager answers', () async {
      final (validator, _, _, partnershipId) =
          await setUpUnapprovedPartnership();
      final create = validator.usableRecords.single;
      expect(create.partnership, partnershipId);

      expect(_statusOf(validator, create), RecordStatus.pendingApproval);
    });

    test('a ratio proposal the manager rejects is rejected', () async {
      final (validator, investor, manager, partnershipId) =
          await setUpPartnership();
      final proposal = await investor.next(
        partnership: partnershipId,
        type: 'ratio_proposal',
        body: {
          'ratio': {'investor': 70, 'manager': 30},
          'effectiveFrom': '2026-11-01',
        },
      );
      final reject = await manager.next(
        partnership: partnershipId,
        type: 'reject',
        refersTo: proposal.id,
      );
      await _receive(validator, [proposal, reject]);

      expect(_statusOf(validator, proposal), RecordStatus.rejected);
    });

    test('the investor\'s own invest, reversed by the investor, is cancelled', () async {
      final (validator, investor, _, partnershipId) =
          await setUpPartnership();
      final invest = await investor.next(
        partnership: partnershipId,
        type: 'invest',
        body: const {'amount': 10000},
      );
      final reversal = await investor.next(
        partnership: partnershipId,
        type: 'reversal',
        refersTo: invest.id,
      );
      await _receive(validator, [invest, reversal]);

      expect(_statusOf(validator, invest), RecordStatus.cancelledByReversal);
      expect(_statusOf(validator, reversal), RecordStatus.effective);
    });

    test('an expense that does not fit the budget is over budget', () async {
      final (validator, investor, manager, partnershipId) =
          await setUpPartnership();
      final budget = await investor.next(
        partnership: partnershipId,
        type: 'budget_proposal',
        body: {'grantee': manager.key, 'amount': 5000},
      );
      final approve = await manager.next(
        partnership: partnershipId,
        type: 'approve',
        refersTo: budget.id,
      );
      final expense = await manager.next(
        partnership: partnershipId,
        type: 'expense',
        body: const {'amount': 9000, 'receiptHash': null},
        refersTo: budget.id,
      );
      await _receive(validator, [budget, approve, expense]);

      expect(_statusOf(validator, expense), RecordStatus.overBudget);
    });

    test('an approve that answers a settlement out of order is invalid evidence', () async {
      final (validator, investor, manager, partnershipId) =
          await setUpPartnership();
      final create = validator.usableRecords.singleWhere(
        (r) => r.type == 'partnership_create',
      );
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
      await _receive(validator, [s1, s2, approveS2Early]);

      expect(_statusOf(validator, approveS2Early), RecordStatus.invalidResponse);
    });

    test('a second answer from the same partner is an ignored response', () async {
      final (validator, investor, manager, partnershipId) =
          await setUpPartnership();
      final budget = await investor.next(
        partnership: partnershipId,
        type: 'budget_proposal',
        body: {'grantee': manager.key, 'amount': 5000},
      );
      final approve = await manager.next(
        partnership: partnershipId,
        type: 'approve',
        refersTo: budget.id,
      );
      final secondAnswer = await manager.next(
        partnership: partnershipId,
        type: 'reject',
        refersTo: budget.id,
      );
      await _receive(validator, [budget, approve, secondAnswer]);

      expect(_statusOf(validator, approve), RecordStatus.effective);
      expect(_statusOf(validator, secondAnswer), RecordStatus.ignoredResponse);
    });

    test('a record with the wrong prevHash is chain-invalid', () async {
      final (validator, investor, _, partnershipId) =
          await setUpPartnership();
      final badChain = Record(
        v: 1,
        id: testId('bad-chain'),
        partnership: partnershipId,
        author: investor.key,
        seq: investor.seq + 1,
        prevHash: 'a' * 64,
        type: 'invest',
        body: const {'amount': 10000},
        refersTo: null,
        note: '',
        time: '2026-10-05T09:00:00Z',
        sig: '',
      );
      final signed = await signRecord(badChain, investor.keyPair);
      expect(
        await validator.receiveText(canonicalJson(signed.toJson())),
        ReceiveOutcome.chainInvalid,
      );

      expect(_statusOf(validator, signed), RecordStatus.chainInvalid);
    });

    test('two different signed records at the same seq are equivocating', () async {
      final (validator, investor, _, partnershipId) =
          await setUpPartnership();
      final nextSeq = investor.seq + 1;
      final prevHash = investor.prevHash;

      Future<Record> variant(int amount) async {
        final unsigned = Record(
          v: 1,
          id: testId('invest-variant-$amount'),
          partnership: partnershipId,
          author: investor.key,
          seq: nextSeq,
          prevHash: prevHash,
          type: 'invest',
          body: {'amount': amount},
          refersTo: null,
          note: '',
          time: '2026-10-05T09:00:00Z',
          sig: '',
        );
        return signRecord(unsigned, investor.keyPair);
      }

      final first = await variant(10000);
      final second = await variant(20000);
      expect(
        await validator.receiveText(canonicalJson(first.toJson())),
        ReceiveOutcome.accepted,
      );
      expect(
        await validator.receiveText(canonicalJson(second.toJson())),
        ReceiveOutcome.equivocating,
      );

      expect(_statusOf(validator, first), RecordStatus.equivocating);
      expect(_statusOf(validator, second), RecordStatus.equivocating);
    });

    test(
      'an expense with no effective budget to spend from is not counted, '
      'for no more specific reason',
      () async {
        final (validator, _, manager, partnershipId) =
            await setUpPartnership();
        final expense = await manager.next(
          partnership: partnershipId,
          type: 'expense',
          body: const {'amount': 5000, 'receiptHash': null},
          refersTo: testId('no-such-budget'),
        );
        await _receive(validator, [expense]);

        expect(_statusOf(validator, expense), RecordStatus.notCounted);
      },
    );
  });
}
