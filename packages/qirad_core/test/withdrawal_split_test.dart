import 'package:qirad_core/qirad_core.dart';
import 'package:test/test.dart';

import 'support/partnership_fixture.dart';

Future<void> _receive(Validator validator, Iterable<Record> records) async {
  for (final record in records) {
    await validator.receiveText(canonicalJson(record.toJson()));
  }
}

WithdrawalSplit _investorSplit(Validator validator, ChainAuthor investor) =>
    withdrawalSplits(
      validator.usableRecords,
      partnershipKeys: validator.partnershipKeys!,
    )[investor.key]!;

void main() {
  group('withdrawn ahead of settled profit and owed back (spec 6.7)', () {
    test(
      'the example: 500 withdrawn, 360 own, a correction of -99 gives owed back 99 and ahead 140',
      () async {
        final (validator, investor, manager, partnershipId) =
            await setUpPartnership();
        // Period 1: sales 600 and 165, expense 165. Result 600, so the investor's
        // own share is 60% of 600 = 360.
        final budget = await investor.next(
          partnership: partnershipId,
          type: 'budget_proposal',
          body: {'grantee': manager.key, 'amount': 10000},
        );
        // Investor seq 3: the investor withdraws 500 of profit.
        final withdraw = await investor.next(
          partnership: partnershipId,
          type: 'withdraw_request',
          body: {'amount': 500, 'kind': 'profit'},
        );
        final consent = await manager.next(
          partnership: partnershipId,
          type: 'approve',
          refersTo: budget.id,
        );
        final sale600 = await manager.next(
          partnership: partnershipId,
          type: 'sale',
          body: {'amount': 600},
        );
        final sale165 = await manager.next(
          partnership: partnershipId,
          type: 'sale',
          body: {'amount': 165},
        );
        final expense = await manager.next(
          partnership: partnershipId,
          type: 'expense',
          refersTo: budget.id,
          body: {'amount': 165, 'receiptHash': null},
        );
        final approveWithdraw = await manager.next(
          partnership: partnershipId,
          type: 'approve',
          refersTo: withdraw.id,
        );
        final s1 = await manager.next(
          partnership: partnershipId,
          type: settlementType,
          body: {
            'cut': {investor.key: 3, manager.key: 5},
          },
        );
        final approveS1 = await investor.next(
          partnership: partnershipId,
          type: 'approve',
          refersTo: s1.id,
        );
        // Period 2: the 165 sale is reversed, so the result is 435.
        // The investor's share falls from 360 to 261, a correction of -99.
        final reversal = await manager.next(
          partnership: partnershipId,
          type: 'reversal',
          refersTo: sale165.id,
        );
        final approveReversal = await investor.next(
          partnership: partnershipId,
          type: 'approve',
          refersTo: reversal.id,
        );
        final s2 = await manager.next(
          partnership: partnershipId,
          type: settlementType,
          body: {
            'cut': {investor.key: 5, manager.key: 7},
          },
        );
        final approveS2 = await investor.next(
          partnership: partnershipId,
          type: 'approve',
          refersTo: s2.id,
        );
        await _receive(validator, [
          budget,
          withdraw,
          consent,
          sale600,
          sale165,
          expense,
          approveWithdraw,
          s1,
          approveS1,
          reversal,
          approveReversal,
          s2,
          approveS2,
        ]);

        final periods = periodShares(
          validator.usableRecords,
          partnershipKeys: validator.partnershipKeys!,
        );
        expect(periods.first.shares.investor, 360);
        expect(periods[1].correction.investor, -99);

        final split = _investorSplit(validator, investor);
        expect(split.withdrawn, 500);
        expect(split.owedBack, 99);
        expect(split.aheadOfSettled, 140);
      },
    );

    test('a correction that increases a share gives owed back 0', () async {
      final (validator, investor, manager, partnershipId) =
          await setUpPartnership();
      final budget = await investor.next(
        partnership: partnershipId,
        type: 'budget_proposal',
        body: {'grantee': manager.key, 'amount': 10000},
      );
      // Investor seq 3: withdraws 500 of profit.
      final withdraw = await investor.next(
        partnership: partnershipId,
        type: 'withdraw_request',
        body: {'amount': 500, 'kind': 'profit'},
      );
      final consent = await manager.next(
        partnership: partnershipId,
        type: 'approve',
        refersTo: budget.id,
      );
      // Period 1: sale 600, expense 100. Result 500, own share 300.
      final sale = await manager.next(
        partnership: partnershipId,
        type: 'sale',
        body: {'amount': 600},
      );
      final expense = await manager.next(
        partnership: partnershipId,
        type: 'expense',
        refersTo: budget.id,
        body: {'amount': 100, 'receiptHash': null},
      );
      final approveWithdraw = await manager.next(
        partnership: partnershipId,
        type: 'approve',
        refersTo: withdraw.id,
      );
      final s1 = await manager.next(
        partnership: partnershipId,
        type: settlementType,
        body: {
          'cut': {investor.key: 3, manager.key: 4},
        },
      );
      final approveS1 = await investor.next(
        partnership: partnershipId,
        type: 'approve',
        refersTo: s1.id,
      );
      // Period 2: the expense is reversed, so the result is 600.
      // The investor's share rises from 300 to 360, a correction of +60.
      final reversal = await manager.next(
        partnership: partnershipId,
        type: 'reversal',
        refersTo: expense.id,
      );
      final approveReversal = await investor.next(
        partnership: partnershipId,
        type: 'approve',
        refersTo: reversal.id,
      );
      final s2 = await manager.next(
        partnership: partnershipId,
        type: settlementType,
        body: {
          'cut': {investor.key: 5, manager.key: 6},
        },
      );
      final approveS2 = await investor.next(
        partnership: partnershipId,
        type: 'approve',
        refersTo: s2.id,
      );
      await _receive(validator, [
        budget,
        withdraw,
        consent,
        sale,
        expense,
        approveWithdraw,
        s1,
        approveS1,
        reversal,
        approveReversal,
        s2,
        approveS2,
      ]);

      final split = _investorSplit(validator, investor);
      expect(split.withdrawn, 500);
      expect(split.owedBack, 0);
      // The excess over the settled share fell from 200 to 140.
      expect(split.aheadOfSettled, 140);
    });

    test(
      'a withdrawal above the settled share is all ahead, with owed back 0',
      () async {
        final (validator, investor, manager, partnershipId) =
            await setUpPartnership();
        // Investor seq 2: withdraws 500 of profit, before any settlement.
        final withdraw = await investor.next(
          partnership: partnershipId,
          type: 'withdraw_request',
          body: {'amount': 500, 'kind': 'profit'},
        );
        // Manager seq 1: approves the withdrawal. Manager seq 2: sale 600.
        final approveWithdraw = await manager.next(
          partnership: partnershipId,
          type: 'approve',
          refersTo: withdraw.id,
        );
        final sale = await manager.next(
          partnership: partnershipId,
          type: 'sale',
          body: {'amount': 600},
        );
        // Manager seq 3: S1 closes period 1. Investor seq 3 approves it.
        final s1 = await manager.next(
          partnership: partnershipId,
          type: settlementType,
          body: {
            'cut': {investor.key: 2, manager.key: 2},
          },
        );
        final approveS1 = await investor.next(
          partnership: partnershipId,
          type: 'approve',
          refersTo: s1.id,
        );
        await _receive(validator, [
          withdraw,
          approveWithdraw,
          sale,
          s1,
          approveS1,
        ]);

        // Own share 360, withdrawn 500: the excess of 140 is all ahead of settled
        // profit. No correction exists, so nothing is owed.
        final split = _investorSplit(validator, investor);
        expect(split.withdrawn, 500);
        expect(split.aheadOfSettled, 140);
        expect(split.owedBack, 0);
      },
    );

    test(
      'a correction in the open period does not affect owed back until that period is settled',
      () async {
        final (validator, investor, manager, partnershipId) =
            await setUpPartnership();
        final budget = await investor.next(
          partnership: partnershipId,
          type: 'budget_proposal',
          body: {'grantee': manager.key, 'amount': 10000},
        );
        final withdraw = await investor.next(
          partnership: partnershipId,
          type: 'withdraw_request',
          body: {'amount': 500, 'kind': 'profit'},
        );
        final consent = await manager.next(
          partnership: partnershipId,
          type: 'approve',
          refersTo: budget.id,
        );
        final sale600 = await manager.next(
          partnership: partnershipId,
          type: 'sale',
          body: {'amount': 600},
        );
        final sale165 = await manager.next(
          partnership: partnershipId,
          type: 'sale',
          body: {'amount': 165},
        );
        final expense = await manager.next(
          partnership: partnershipId,
          type: 'expense',
          refersTo: budget.id,
          body: {'amount': 165, 'receiptHash': null},
        );
        final approveWithdraw = await manager.next(
          partnership: partnershipId,
          type: 'approve',
          refersTo: withdraw.id,
        );
        final s1 = await manager.next(
          partnership: partnershipId,
          type: settlementType,
          body: {
            'cut': {investor.key: 3, manager.key: 5},
          },
        );
        final approveS1 = await investor.next(
          partnership: partnershipId,
          type: 'approve',
          refersTo: s1.id,
        );
        final reversal = await manager.next(
          partnership: partnershipId,
          type: 'reversal',
          refersTo: sale165.id,
        );
        final approveReversal = await investor.next(
          partnership: partnershipId,
          type: 'approve',
          refersTo: reversal.id,
        );
        // The reversal is in period 2, which is still open: no S2 yet.
        await _receive(validator, [
          budget,
          withdraw,
          consent,
          sale600,
          sale165,
          expense,
          approveWithdraw,
          s1,
          approveS1,
          reversal,
          approveReversal,
        ]);

        final before = _investorSplit(validator, investor);
        expect(before.owedBack, 0, reason: 'period 2 is still open');
        expect(before.aheadOfSettled, 140);

        // Manager seq 8: S2 closes period 2 (its cut covers the reversal, seq 7).
        // Investor seq 6 approves it.
        final s2 = await manager.next(
          partnership: partnershipId,
          type: settlementType,
          body: {
            'cut': {investor.key: 5, manager.key: 7},
          },
        );
        final approveS2 = await investor.next(
          partnership: partnershipId,
          type: 'approve',
          refersTo: s2.id,
        );
        await _receive(validator, [s2, approveS2]);

        final after = _investorSplit(validator, investor);
        expect(after.owedBack, 99);
        expect(after.aheadOfSettled, 140);
      },
    );
  });
}
