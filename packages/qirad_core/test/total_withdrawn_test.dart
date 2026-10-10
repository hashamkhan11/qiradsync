import 'package:qirad_core/qirad_core.dart';
import 'package:test/test.dart';

import 'support/cut_helper.dart';
import 'support/partnership_fixture.dart';

Future<void> _receive(Validator validator, Iterable<Record> records) async {
  for (final record in records) {
    await validator.receiveText(canonicalJson(record.toJson()));
  }
}

Map<String, int> _totals(Validator validator) => totalProfitWithdrawn(
  validator.usableRecords,
  partnershipKeys: validator.partnershipKeys!,
);

void main() {
  group('total profit withdrawn (decision Q1, spec 6.7)', () {
    test(
      'a 500 profit withdrawal before any settlement: total 500, and no split yet',
      () async {
        final (validator, investor, manager, partnershipId) =
            await setUpPartnership();
        final withdraw = await investor.next(
          partnership: partnershipId,
          type: 'withdraw_request',
          body: {'amount': 500, 'kind': 'profit'},
        );
        final approveWithdraw = await manager.next(
          partnership: partnershipId,
          type: 'approve',
          refersTo: withdraw.id,
        );
        await _receive(validator, [withdraw, approveWithdraw]);

        expect(_totals(validator)[investor.key], 500);
        expect(_totals(validator)[manager.key], 0);

        // No closed period yet, so the split is all zero. The dashboard shows
        // "not yet compared to settled profit" instead of a split.
        final split = withdrawalSplits(
          validator.usableRecords,
          partnershipKeys: validator.partnershipKeys!,
        )[investor.key]!;
        expect(split.withdrawn, 0);
        expect(split.aheadOfSettled, 0);
        expect(split.owedBack, 0);
      },
    );

    test(
      'a withdrawal the manager has not approved is not in the total',
      () async {
        final (validator, investor, _, partnershipId) =
            await setUpPartnership();
        // Investor seq 2: withdraws 500. Nobody approves it, so it is not effective.
        final withdraw = await investor.next(
          partnership: partnershipId,
          type: 'withdraw_request',
          body: {'amount': 500, 'kind': 'profit'},
        );
        await _receive(validator, [withdraw]);

        expect(_totals(validator)[investor.key], 0);
      },
    );

    test(
      'a withdrawal after the last settlement counts in the total, not in the split',
      () async {
        final (validator, investor, manager, partnershipId) =
            await setUpPartnership();
        // Withdraws 300. The manager approves it.
        final withdraw1 = await investor.next(
          partnership: partnershipId,
          type: 'withdraw_request',
          body: {'amount': 300, 'kind': 'profit'},
        );
        final approve1 = await manager.next(
          partnership: partnershipId,
          type: 'approve',
          refersTo: withdraw1.id,
        );
        // Sale 600. S1 closes period 1, reaching the withdrawal and the sale.
        final sale = await manager.next(
          partnership: partnershipId,
          type: 'sale',
          body: {'amount': 600},
        );
        final s1Cut = cutUpTo(
          investor,
          manager,
          upToInvestor: withdraw1,
          upToManager: sale,
        );
        expect(
          withdraw1.seq,
          lessThanOrEqualTo(s1Cut[investor.key]!),
          reason: 'the withdrawal is inside the cut',
        );
        expect(
          sale.seq,
          lessThanOrEqualTo(s1Cut[manager.key]!),
          reason: 'the sale is inside the cut',
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
        // Withdraws 100 after S1. The manager approves it.
        final withdraw2 = await investor.next(
          partnership: partnershipId,
          type: 'withdraw_request',
          body: {'amount': 100, 'kind': 'profit'},
        );
        final approve2 = await manager.next(
          partnership: partnershipId,
          type: 'approve',
          refersTo: withdraw2.id,
        );
        await _receive(validator, [
          withdraw1,
          approve1,
          sale,
          s1,
          approveS1,
          withdraw2,
          approve2,
        ]);

        // The total includes both withdrawals.
        expect(_totals(validator)[investor.key], 400);

        // The split uses the closed period only: 300 withdrawn, own share 360.
        final split = withdrawalSplits(
          validator.usableRecords,
          partnershipKeys: validator.partnershipKeys!,
        )[investor.key]!;
        expect(split.withdrawn, 300);
        expect(split.aheadOfSettled, 0);
        expect(split.owedBack, 0);
      },
    );
  });
}
