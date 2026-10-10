import 'package:qirad_core/qirad_core.dart';
import 'package:test/test.dart';

import 'support/cut_helper.dart';
import 'support/partnership_fixture.dart';

Future<void> _receive(Validator validator, Iterable<Record> records) async {
  for (final record in records) {
    await validator.receiveText(canonicalJson(record.toJson()));
  }
}

void main() {
  group('loss carry-forward (spec 6.7)', () {
    test(
      'a profit in a later period covers the earlier loss before anything is shared',
      () async {
        final (validator, investor, manager, partnershipId) =
            await setUpPartnership();
        // Budget 10,000 for the manager, with consent.
        final budget = await investor.next(
          partnership: partnershipId,
          type: 'budget_proposal',
          body: {'grantee': manager.key, 'amount': 10000},
        );
        final consent = await manager.next(
          partnership: partnershipId,
          type: 'approve',
          refersTo: budget.id,
        );
        // Expense 300 with no sales, so period 1 is a loss of 300.
        final expense = await manager.next(
          partnership: partnershipId,
          type: 'expense',
          refersTo: budget.id,
          body: {'amount': 300, 'receiptHash': null},
        );
        // S1 closes period 1: it must reach the expense, or the loss it
        // creates stays outside the settled period.
        final s1Cut = cutUpTo(investor, manager, upToInvestor: budget, upToManager: expense);
        expect(
          expense.seq,
          lessThanOrEqualTo(s1Cut[manager.key]!),
          reason: 'the expense is inside S1\'s cut',
        );
        final s1 = await manager.next(
          partnership: partnershipId,
          type: settlementType,
          body: {'cut': s1Cut},
        );
        final approveS1 = await investor.next(
          partnership: partnershipId,
          type: 'approve',
          refersTo: s1.id,
        );
        // Sale 500 in period 2. S2 closes it.
        final sale = await manager.next(
          partnership: partnershipId,
          type: 'sale',
          body: {'amount': 500},
        );
        final s2Cut = cutUpTo(investor, manager, upToInvestor: budget, upToManager: sale);
        expect(
          sale.seq,
          lessThanOrEqualTo(s2Cut[manager.key]!),
          reason: 'the sale is inside S2\'s cut',
        );
        final s2 = await manager.next(
          partnership: partnershipId,
          type: settlementType,
          body: {'cut': s2Cut},
        );
        final approveS2 = await investor.next(
          partnership: partnershipId,
          type: 'approve',
          refersTo: s2.id,
        );
        await _receive(validator, [
          budget,
          consent,
          expense,
          s1,
          approveS1,
          sale,
          s2,
          approveS2,
        ]);

        final periods = periodShares(
          validator.usableRecords,
          partnershipKeys: validator.partnershipKeys!,
        );

        // Period 1: loss of 300. Nothing is shared, and the deficit is 300.
        expect(periods[0].result, -300);
        expect(periods[0].shares.investor, 0);
        expect(periods[0].shares.manager, 0);
        expect(periods[0].deficitAfter, 300);

        // Period 2: profit 500. The first 300 covers the deficit. Only 200 is
        // shared, 60/40, so the investor gets 120 and the manager gets 80.
        expect(periods[1].result, 500);
        expect(periods[1].shares.investor, 120);
        expect(periods[1].shares.manager, 80);
        expect(periods[1].deficitAfter, 0);
      },
    );
  });
}
