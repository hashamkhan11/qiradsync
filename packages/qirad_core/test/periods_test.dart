import 'package:qirad_core/qirad_core.dart';
import 'package:test/test.dart';

import 'support/partnership_fixture.dart';

Future<void> _receive(Validator validator, Iterable<Record> records) async {
  for (final record in records) {
    await validator.receiveText(canonicalJson(record.toJson()));
  }
}

List<PeriodShares> _periods(Validator validator) => periodShares(
  validator.usableRecords,
  partnershipKeys: validator.partnershipKeys!,
);

void main() {
  group('period shares and prior-period adjustments (spec 6.7, step 4c)', () {
    // Every expense needs an approved budget whose grantee is the manager
    // (spec 6.4). Each test starts with the same budget: investor seq 2, and
    // the manager's consent at manager seq 1.
    Future<(Record, Record)> budget(
      Validator validator,
      ChainAuthor investor,
      ChainAuthor manager,
      String partnershipId,
    ) async {
      final proposal = await investor.next(
        partnership: partnershipId,
        type: 'budget_proposal',
        body: {'grantee': manager.key, 'amount': 10000},
      );
      final consent = await manager.next(
        partnership: partnershipId,
        type: 'approve',
        refersTo: proposal.id,
      );
      return (proposal, consent);
    }

    test(
      'a small correction changes only the earlier period\'s shares, booked in the later period',
      () async {
        final (validator, investor, manager, partnershipId) =
            await setUpPartnership();
        final (proposal, consent) = await budget(
          validator,
          investor,
          manager,
          partnershipId,
        );
        // Manager seq 2: sale 1000. Manager seq 3: expense 100 under the budget.
        final sale = await manager.next(
          partnership: partnershipId,
          type: 'sale',
          body: {'amount': 1000},
        );
        final expense = await manager.next(
          partnership: partnershipId,
          type: 'expense',
          refersTo: proposal.id,
          body: {'amount': 100, 'receiptHash': null},
        );
        // Manager seq 4: S1 closes period 1. Investor seq 3 approves it.
        final s1 = await manager.next(
          partnership: partnershipId,
          type: settlementType,
          body: {
            'cut': {investor.key: 2, manager.key: 3},
          },
        );
        final approveS1 = await investor.next(
          partnership: partnershipId,
          type: 'approve',
          refersTo: s1.id,
        );
        await _receive(validator, [
          proposal,
          consent,
          sale,
          expense,
          s1,
          approveS1,
        ]);

        final before = _periods(validator);
        expect(before.first.result, 900);
        expect(before.first.shares.investor, 540);
        expect(before.first.shares.manager, 360);

        // Manager seq 5: reverses the expense. Investor seq 4 approves it.
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
        // Manager seq 6: S2 closes period 2. Investor seq 5 approves it.
        final s2 = await manager.next(
          partnership: partnershipId,
          type: settlementType,
          body: {
            'cut': {investor.key: 4, manager.key: 5},
          },
        );
        final approveS2 = await investor.next(
          partnership: partnershipId,
          type: 'approve',
          refersTo: s2.id,
        );
        await _receive(validator, [reversal, approveReversal, s2, approveS2]);

        final periods = _periods(validator);
        final period1 = periods[0];
        final period2 = periods[1];

        // Period 1's own shares stay as they were settled.
        expect(period1.result, 900);
        expect(period1.shares.investor, 540);
        expect(period1.shares.manager, 360);

        // Period 2 books the change: 1000 instead of 900, so +60 and +40.
        expect(period2.correction.investor, 60);
        expect(period2.correction.manager, 40);
        expect(period2.deficitChange, 0);
        // Period 2 itself has no money of its own.
        expect(period2.result, 0);
        expect(period2.shares.investor, 0);
        expect(period2.shares.manager, 0);
      },
    );

    test(
      'a loss period grows the deficit and gives the manager nothing',
      () async {
        final (validator, investor, manager, partnershipId) =
            await setUpPartnership();
        final (proposal, consent) = await budget(
          validator,
          investor,
          manager,
          partnershipId,
        );
        // Manager seq 2: expense 300, with no sales. Period 1 is a loss of 300.
        final expense1 = await manager.next(
          partnership: partnershipId,
          type: 'expense',
          refersTo: proposal.id,
          body: {'amount': 300, 'receiptHash': null},
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
        // Manager seq 4: a second expense of 200, a loss in period 2.
        final expense2 = await manager.next(
          partnership: partnershipId,
          type: 'expense',
          refersTo: proposal.id,
          body: {'amount': 200, 'receiptHash': null},
        );
        // Manager seq 5: S2 closes period 2. Investor seq 4 approves it.
        final s2 = await manager.next(
          partnership: partnershipId,
          type: settlementType,
          body: {
            'cut': {investor.key: 3, manager.key: 4},
          },
        );
        final approveS2 = await investor.next(
          partnership: partnershipId,
          type: 'approve',
          refersTo: s2.id,
        );
        await _receive(validator, [
          proposal,
          consent,
          expense1,
          s1,
          approveS1,
          expense2,
          s2,
          approveS2,
        ]);

        final periods = _periods(validator);
        final period1 = periods[0];
        final period2 = periods[1];

        expect(period1.result, -300);
        expect(period1.shares.investor, 0);
        expect(period1.shares.manager, 0);
        expect(period1.deficitAfter, 300);

        expect(period2.result, -200);
        expect(period2.shares.investor, 0);
        expect(period2.shares.manager, 0);
        expect(period2.deficitAfter, 500, reason: 'the deficit grows by 200');
        expect(period2.correction.investor, 0);
        expect(period2.correction.manager, 0);
      },
    );

    test(
      'a profit period that becomes a loss goes to zero shares and leaves a deficit',
      () async {
        final (validator, investor, manager, partnershipId) =
            await setUpPartnership();
        final (proposal, consent) = await budget(
          validator,
          investor,
          manager,
          partnershipId,
        );
        // Manager seq 2: sale 1000. Manager seq 3: expense 200. Result 800.
        final sale = await manager.next(
          partnership: partnershipId,
          type: 'sale',
          body: {'amount': 1000},
        );
        final expense = await manager.next(
          partnership: partnershipId,
          type: 'expense',
          refersTo: proposal.id,
          body: {'amount': 200, 'receiptHash': null},
        );
        // Manager seq 4: S1 closes period 1. Investor seq 3 approves it.
        final s1 = await manager.next(
          partnership: partnershipId,
          type: settlementType,
          body: {
            'cut': {investor.key: 2, manager.key: 3},
          },
        );
        final approveS1 = await investor.next(
          partnership: partnershipId,
          type: 'approve',
          refersTo: s1.id,
        );
        await _receive(validator, [
          proposal,
          consent,
          sale,
          expense,
          s1,
          approveS1,
        ]);

        final before = _periods(validator);
        expect(before.first.shares.investor, 480);
        expect(before.first.shares.manager, 320);

        // Manager seq 5: reverses the sale. Investor seq 4 approves it.
        // Period 1 becomes 0 - 200 = -200, a loss.
        final reversal = await manager.next(
          partnership: partnershipId,
          type: 'reversal',
          refersTo: sale.id,
        );
        final approveReversal = await investor.next(
          partnership: partnershipId,
          type: 'approve',
          refersTo: reversal.id,
        );
        // Manager seq 6: S2 closes period 2. Investor seq 5 approves it.
        final s2 = await manager.next(
          partnership: partnershipId,
          type: settlementType,
          body: {
            'cut': {investor.key: 4, manager.key: 5},
          },
        );
        final approveS2 = await investor.next(
          partnership: partnershipId,
          type: 'approve',
          refersTo: s2.id,
        );
        await _receive(validator, [reversal, approveReversal, s2, approveS2]);

        final periods = _periods(validator);
        final period2 = periods[1];

        // The old shares are taken back, and the loss becomes a deficit of 200.
        expect(period2.correction.investor, -480);
        expect(period2.correction.manager, -320);
        expect(period2.deficitChange, 200);
        expect(period2.deficitAfter, 200);
        expect(period2.shares.investor, 0);
        expect(period2.shares.manager, 0);
      },
    );

    group('several corrections to one period', () {
      // Period 1: sales 800, 500 and 200, expense 500. Result 1000 (600/400).
      // A reverses the 800 sale in period 2. B reverses the 500 sale in period 3.
      Future<List<Record>> buildRecords(
        ChainAuthor investor,
        ChainAuthor manager,
        String partnershipId,
      ) async {
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
        final sale800 = await manager.next(
          partnership: partnershipId,
          type: 'sale',
          body: {'amount': 800},
        );
        final sale500 = await manager.next(
          partnership: partnershipId,
          type: 'sale',
          body: {'amount': 500},
        );
        final sale200 = await manager.next(
          partnership: partnershipId,
          type: 'sale',
          body: {'amount': 200},
        );
        final expense = await manager.next(
          partnership: partnershipId,
          type: 'expense',
          refersTo: budget.id,
          body: {'amount': 500, 'receiptHash': null},
        );
        final s1 = await manager.next(
          partnership: partnershipId,
          type: settlementType,
          body: {
            'cut': {investor.key: 2, manager.key: 5},
          },
        );
        final approveS1 = await investor.next(
          partnership: partnershipId,
          type: 'approve',
          refersTo: s1.id,
        );
        final reversalA = await manager.next(
          partnership: partnershipId,
          type: 'reversal',
          refersTo: sale800.id,
        );
        final approveA = await investor.next(
          partnership: partnershipId,
          type: 'approve',
          refersTo: reversalA.id,
        );
        final s2 = await manager.next(
          partnership: partnershipId,
          type: settlementType,
          body: {
            'cut': {investor.key: 4, manager.key: 7},
          },
        );
        final approveS2 = await investor.next(
          partnership: partnershipId,
          type: 'approve',
          refersTo: s2.id,
        );
        final reversalB = await manager.next(
          partnership: partnershipId,
          type: 'reversal',
          refersTo: sale500.id,
        );
        final approveB = await investor.next(
          partnership: partnershipId,
          type: 'approve',
          refersTo: reversalB.id,
        );
        final s3 = await manager.next(
          partnership: partnershipId,
          type: settlementType,
          body: {
            'cut': {investor.key: 6, manager.key: 9},
          },
        );
        final approveS3 = await investor.next(
          partnership: partnershipId,
          type: 'approve',
          refersTo: s3.id,
        );
        return [
          budget,
          consent,
          sale800,
          sale500,
          sale200,
          expense,
          s1,
          approveS1,
          reversalA,
          approveA,
          s2,
          approveS2,
          reversalB,
          approveB,
          s3,
          approveS3,
        ];
      }

      test(
        'A books -480/-320, B books -120/-80 and +300 deficit, and period 1 keeps its own view',
        () async {
          final (validator, investor, manager, partnershipId) =
              await setUpPartnership();
          final records = await buildRecords(investor, manager, partnershipId);
          await _receive(validator, records);

          final periods = _periods(validator);
          final period1 = periods[0];
          final period2 = periods[1];
          final period3 = periods[2];

          expect(period1.result, 1000);
          expect(period1.shares.investor, 600);
          expect(period1.shares.manager, 400);

          expect(period2.correction.investor, -480);
          expect(period2.correction.manager, -320);
          expect(period2.deficitChange, 0);

          expect(period3.correction.investor, -120);
          expect(period3.correction.manager, -80);
          expect(period3.deficitChange, 300);
          expect(period3.deficitAfter, 300);

          // The sum of the corrections: -600 and -400. Period 1's net shares
          // end at 0/0, and the carried deficit is 300.
          expect(
            period2.correction.investor + period3.correction.investor,
            -600,
          );
          expect(period2.correction.manager + period3.correction.manager, -400);

          // Period 1 itself is a settled view, so it does not change.
          expect(period1.result, 1000);
          expect(period1.shares.investor, 600);
          expect(period1.shares.manager, 400);
        },
      );

      test(
        'the same records in two arrival orders give identical shares',
        () async {
          final (validator, investor, manager, partnershipId) =
              await setUpPartnership();
          final records = await buildRecords(investor, manager, partnershipId);
          await _receive(validator, records);

          // A second phone: the create first, then the records in reverse order.
          final reversed = Validator.unpinnedForTesting();
          final create = validator.usableRecords.firstWhere(
            (r) => r.type == 'partnership_create',
          );
          await _receive(reversed, [create]);
          await _receive(reversed, records.reversed);

          String show(List<PeriodShares> periods) => [
            for (final p in periods)
              '${p.index}:${p.result}:${p.shares.investor}/${p.shares.manager}:'
                  '${p.correction.investor}/${p.correction.manager}:'
                  '${p.deficitChange}:${p.deficitAfter}',
          ].join(' ');

          expect(show(_periods(reversed)), show(_periods(validator)));
        },
      );
    });
  });
}
