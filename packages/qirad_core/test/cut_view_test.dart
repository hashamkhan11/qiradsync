import 'package:qirad_core/qirad_core.dart';
import 'package:test/test.dart';

import 'support/cut_helper.dart';
import 'support/partnership_fixture.dart';

MoneySummary _view(Validator validator, Map<String, int> cut) => cutMoney(
  validator.usableRecords,
  partnershipKeys: validator.partnershipKeys!,
  cut: cut,
);

Future<void> _receive(Validator validator, Iterable<Record> records) async {
  for (final record in records) {
    await validator.receiveText(canonicalJson(record.toJson()));
  }
}

void main() {
  group('a settled period is a pure function of its cut (spec 6.7)', () {
    test(
      'an unanswered withdrawal inside a cut does not block its settlement, and a later approval counts in the later period',
      () async {
        final (validator, investor, manager, partnershipId) =
            await setUpPartnership();
        final create = validator.usableRecords.singleWhere(
          (r) => r.type == 'partnership_create',
        );
        // A profit withdrawal that nobody has answered yet.
        final withdraw = await manager.next(
          partnership: partnershipId,
          type: 'withdraw_request',
          body: {'amount': 300, 'kind': 'profit'},
        );
        // S1 covers the create and the withdrawal.
        final s1 = await manager.next(
          partnership: partnershipId,
          type: settlementType,
          body: {
            'cut': cutUpTo(
              investor,
              manager,
              upToInvestor: create,
              upToManager: withdraw,
            ),
          },
        );
        final approveS1 = await investor.next(
          partnership: partnershipId,
          type: 'approve',
          refersTo: s1.id,
        );
        await _receive(validator, [withdraw, s1, approveS1]);

        // The unanswered withdrawal does not block S1.
        final status = _effective(
          validator,
        ).settlements.singleWhere((s) => s.record.id == s1.id);
        expect(status.state, SettlementState.effective);

        final cut1 = cutUpTo(
          investor,
          manager,
          upToInvestor: create,
          upToManager: withdraw,
        );
        expect(_view(validator, cut1).profitPaid, 0);

        // The late approval of the withdrawal, after cut1.
        final approveWithdraw = await investor.next(
          partnership: partnershipId,
          type: 'approve',
          refersTo: withdraw.id,
        );
        await _receive(validator, [approveWithdraw]);

        // The settled view does not change. Its money appears in the next period.
        expect(_view(validator, cut1).profitPaid, 0);

        // S2 covers the late approval and S1.
        final s2 = await manager.next(
          partnership: partnershipId,
          type: settlementType,
          body: {
            'cut': cutUpTo(
              investor,
              manager,
              upToInvestor: approveWithdraw,
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

        final cut2 = cutUpTo(
          investor,
          manager,
          upToInvestor: approveWithdraw,
          upToManager: s1,
        );
        expect(_view(validator, cut2).profitPaid, 300);
        final period2 = periodMoney(
          validator.usableRecords,
          partnershipKeys: validator.partnershipKeys!,
          from: cut1,
          to: cut2,
        );
        expect(period2.profitPaid, 300);
        expect(_view(validator, cut1).profitPaid, 0, reason: 'still unchanged');
      },
    );

    test(
      'a settled view is unchanged after a late budget approval, and the expense is booked in the period where the budget becomes effective',
      () async {
        final (validator, investor, manager, partnershipId) =
            await setUpPartnership();
        // A budget for the manager. It needs the manager's consent.
        final budget = await investor.next(
          partnership: partnershipId,
          type: 'budget_proposal',
          body: {'grantee': manager.key, 'amount': 1000},
        );
        // An expense of 300 under that budget.
        final expense = await manager.next(
          partnership: partnershipId,
          type: 'expense',
          refersTo: budget.id,
          body: {'amount': 300},
        );
        // S1 closes the budget and the expense.
        final s1 = await manager.next(
          partnership: partnershipId,
          type: settlementType,
          body: {
            'cut': cutUpTo(
              investor,
              manager,
              upToInvestor: budget,
              upToManager: expense,
            ),
          },
        );
        // Approves S1.
        final approveS1 = await investor.next(
          partnership: partnershipId,
          type: 'approve',
          refersTo: s1.id,
        );
        await _receive(validator, [budget, expense, s1, approveS1]);

        final cut1 = cutUpTo(
          investor,
          manager,
          upToInvestor: budget,
          upToManager: expense,
        );
        expect(_view(validator, cut1).result, 0, reason: 'no budget consent');

        // The late budget consent, after cut1.
        final consent = await manager.next(
          partnership: partnershipId,
          type: 'approve',
          refersTo: budget.id,
        );
        await _receive(validator, [consent]);

        // The settled view stays the same. The expense is outside the consent.
        expect(_view(validator, cut1).result, 0);

        // S2 covers the consent and S1.
        final s2 = await manager.next(
          partnership: partnershipId,
          type: settlementType,
          body: {
            'cut': cutUpTo(
              investor,
              manager,
              upToInvestor: budget,
              upToManager: consent,
            ),
          },
        );
        final approveS2 = await investor.next(
          partnership: partnershipId,
          type: 'approve',
          refersTo: s2.id,
        );
        await _receive(validator, [s2, approveS2]);

        final cut2 = cutUpTo(
          investor,
          manager,
          upToInvestor: budget,
          upToManager: consent,
        );
        expect(_view(validator, cut2).result, -300);
        final period2 = periodMoney(
          validator.usableRecords,
          partnershipKeys: validator.partnershipKeys!,
          from: cut1,
          to: cut2,
        );
        expect(period2.result, -300);
        expect(_view(validator, cut1).result, 0, reason: 'still unchanged');
      },
    );
  });
}

Effectiveness _effective(Validator validator) => computeEffective(
  validator.usableRecords,
  partnershipKeys: validator.partnershipKeys!,
);
