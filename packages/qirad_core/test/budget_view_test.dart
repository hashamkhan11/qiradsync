import 'package:qirad_core/qirad_core.dart';
import 'package:test/test.dart';

import 'support/partnership_fixture.dart';

void main() {
  group('effectiveBudgetsFor (spec section 5, 6.4)', () {
    test('lists only the grantee\'s own effective budgets', () async {
      final (validator, investor, manager, partnershipId) =
          await setUpPartnership();

      // One budget for the manager, approved.
      final managerBudget = await investor.next(
        partnership: partnershipId,
        type: 'budget_proposal',
        body: {'grantee': manager.key, 'amount': 5000},
      );
      final managerApprove = await manager.next(
        partnership: partnershipId,
        type: 'approve',
        refersTo: managerBudget.id,
      );
      // One budget for the investor, approved (the manager proposed it).
      final investorBudget = await manager.next(
        partnership: partnershipId,
        type: 'budget_proposal',
        body: {'grantee': investor.key, 'amount': 3000},
      );
      final investorApprove = await investor.next(
        partnership: partnershipId,
        type: 'approve',
        refersTo: investorBudget.id,
      );
      // A third budget for the manager, never approved — not effective.
      final pendingBudget = await investor.next(
        partnership: partnershipId,
        type: 'budget_proposal',
        body: {'grantee': manager.key, 'amount': 9000},
      );

      for (final r in [
        managerBudget,
        managerApprove,
        investorBudget,
        investorApprove,
        pendingBudget,
      ]) {
        expect(
          await validator.receiveText(canonicalJson(r.toJson())),
          ReceiveOutcome.accepted,
          reason: r.id,
        );
      }

      final forManager = effectiveBudgetsFor(
        validator.usableRecords,
        partnershipKeys: validator.partnershipKeys!,
        grantee: manager.key,
      );
      expect(forManager, {managerBudget.id: 5000});

      final forInvestor = effectiveBudgetsFor(
        validator.usableRecords,
        partnershipKeys: validator.partnershipKeys!,
        grantee: investor.key,
      );
      expect(forInvestor, {investorBudget.id: 3000});
    });

    test('an expense lowers what is left, for the grantee only', () async {
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
        body: {'amount': 2000, 'receiptHash': null},
        refersTo: budget.id,
      );

      for (final r in [budget, approve, expense]) {
        expect(
          await validator.receiveText(canonicalJson(r.toJson())),
          ReceiveOutcome.accepted,
          reason: r.id,
        );
      }

      final left = effectiveBudgetsFor(
        validator.usableRecords,
        partnershipKeys: validator.partnershipKeys!,
        grantee: manager.key,
      );
      expect(left, {budget.id: 3000});
    });
  });
}
