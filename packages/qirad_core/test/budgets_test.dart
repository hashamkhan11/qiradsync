import 'package:qirad_core/qirad_core.dart';
import 'package:test/test.dart';

import 'support/partnership_fixture.dart';

Future<Effectiveness> _effective(Validator validator) async => computeEffective(
  validator.usableRecords,
  partnershipKeys: validator.partnershipKeys!,
);

/// The investor proposes a budget for the manager, and the manager approves it.
Future<(Record, Record)> _approvedBudget(
  ChainAuthor investor,
  ChainAuthor manager,
  String partnershipId, {
  int amount = 10000,
}) async {
  final budget = await investor.next(
    partnership: partnershipId,
    type: 'budget_proposal',
    body: {'grantee': manager.key, 'amount': amount},
  );
  final approve = await manager.next(
    partnership: partnershipId,
    type: 'approve',
    refersTo: budget.id,
  );
  return (budget, approve);
}

Future<Record> _expense(
  ChainAuthor manager,
  String partnershipId,
  Record budget,
  Object amount,
) => manager.next(
  partnership: partnershipId,
  type: 'expense',
  body: {'amount': amount, 'receiptHash': null},
  refersTo: budget.id,
);

Future<void> _receiveInOrder(Validator validator, List<Record> records) async {
  for (final record in records) {
    expect(
      await validator.receiveText(canonicalJson(record.toJson())),
      ReceiveOutcome.accepted,
      reason: record.id,
    );
  }
}

void main() {
  group('monotonic budget (spec section 6.4)', () {
    test(
      'expenses are counted in order, and an over-budget one is flagged',
      () async {
        final (validator, investor, manager, partnershipId) =
            await setUpPartnership();
        final (budget, approve) = await _approvedBudget(
          investor,
          manager,
          partnershipId,
        );
        final e1 = await _expense(manager, partnershipId, budget, 4000);
        final e2 = await _expense(manager, partnershipId, budget, 3000);
        final e3 = await _expense(manager, partnershipId, budget, 5000);
        await _receiveInOrder(validator, [budget, approve, e1, e2, e3]);

        final effective = await _effective(validator);

        expect(effective.expenseStatus, {
          e1.id: ExpenseStatus.valid,
          e2.id: ExpenseStatus.valid,
          e3.id: ExpenseStatus.overBudget,
        });
        expect(effective.budgetUsed[budget.id], 7000);
        expect(effective.isEffective(e3), isFalse);
      },
    );

    test(
      "the grantee's own reversal frees budget only from its seq onward",
      () async {
        final (validator, investor, manager, partnershipId) =
            await setUpPartnership();
        final (budget, approve) = await _approvedBudget(
          investor,
          manager,
          partnershipId,
        );
        final e1 = await _expense(manager, partnershipId, budget, 4000);
        final e2 = await _expense(manager, partnershipId, budget, 3000);
        final e3 = await _expense(manager, partnershipId, budget, 5000);
        final r2 = await manager.next(
          partnership: partnershipId,
          type: 'reversal',
          refersTo: e2.id,
        );
        final e4 = await _expense(manager, partnershipId, budget, 2000);
        await _receiveInOrder(validator, [budget, approve, e1, e2, e3, r2, e4]);

        final effective = await _effective(validator);

        // E3 was judged over-budget at its own seq. The reversal of E2 frees
        // room only for E4, so E3 stays flagged.
        expect(effective.expenseStatus, {
          e1.id: ExpenseStatus.valid,
          e2.id: ExpenseStatus.valid,
          e3.id: ExpenseStatus.overBudget,
          e4.id: ExpenseStatus.valid,
        });
        expect(effective.budgetUsed[budget.id], 6000);
        expect(effective.isEffective(e2), isFalse);
        expect(effective.isEffective(r2), isTrue);
      },
    );

    test(
      "the other partner's reversal takes effect at the grantee's approve",
      () async {
        final (validator, investor, manager, partnershipId) =
            await setUpPartnership();
        final (budget, budgetApprove) = await _approvedBudget(
          investor,
          manager,
          partnershipId,
        );
        final e1 = await _expense(manager, partnershipId, budget, 4000);
        final e2 = await _expense(manager, partnershipId, budget, 3000);
        final e3 = await _expense(manager, partnershipId, budget, 5000);
        final r2 = await investor.next(
          partnership: partnershipId,
          type: 'reversal',
          refersTo: e2.id,
        );
        // The manager's approve of the investor's reversal sits after E3 in the
        // manager's chain. That position is what frees the budget.
        final approveR2 = await manager.next(
          partnership: partnershipId,
          type: 'approve',
          refersTo: r2.id,
        );
        final e4 = await _expense(manager, partnershipId, budget, 2000);
        await _receiveInOrder(validator, [
          budget,
          budgetApprove,
          e1,
          e2,
          e3,
          r2,
          approveR2,
          e4,
        ]);

        final effective = await _effective(validator);

        expect(effective.expenseStatus, {
          e1.id: ExpenseStatus.valid,
          e2.id: ExpenseStatus.valid,
          e3.id: ExpenseStatus.overBudget,
          e4.id: ExpenseStatus.valid,
        });
        expect(effective.budgetUsed[budget.id], 6000);
      },
    );

    test(
      'until the grantee approves the other partner reversal, it frees nothing',
      () async {
        final (validator, investor, manager, partnershipId) =
            await setUpPartnership();
        final (budget, budgetApprove) = await _approvedBudget(
          investor,
          manager,
          partnershipId,
        );
        final e1 = await _expense(manager, partnershipId, budget, 4000);
        final e2 = await _expense(manager, partnershipId, budget, 3000);
        final r2 = await investor.next(
          partnership: partnershipId,
          type: 'reversal',
          refersTo: e2.id,
        );
        // No approve for R2, so E2 is still counted and E4 does not fit.
        final e4 = await _expense(manager, partnershipId, budget, 4000);
        await _receiveInOrder(validator, [
          budget,
          budgetApprove,
          e1,
          e2,
          r2,
          e4,
        ]);

        final effective = await _effective(validator);

        expect(effective.expenseStatus[e4.id], ExpenseStatus.overBudget);
        expect(effective.budgetUsed[budget.id], 7000);
      },
    );

    test('two reversals of one expense free its amount only once', () async {
      final (validator, investor, manager, partnershipId) =
          await setUpPartnership();
      final (budget, budgetApprove) = await _approvedBudget(
        investor,
        manager,
        partnershipId,
      );
      final e1 = await _expense(manager, partnershipId, budget, 4000);
      final e2 = await _expense(manager, partnershipId, budget, 3000);
      final r1 = await manager.next(
        partnership: partnershipId,
        type: 'reversal',
        refersTo: e2.id,
      );
      final r2 = await investor.next(
        partnership: partnershipId,
        type: 'reversal',
        refersTo: e2.id,
      );
      final approveR2 = await manager.next(
        partnership: partnershipId,
        type: 'approve',
        refersTo: r2.id,
      );
      final e4 = await _expense(manager, partnershipId, budget, 2000);
      await _receiveInOrder(validator, [
        budget,
        budgetApprove,
        e1,
        e2,
        r1,
        r2,
        approveR2,
        e4,
      ]);

      final effective = await _effective(validator);

      // Freed once, so used is 4000 + 2000. Freeing twice would give 3000.
      expect(effective.budgetUsed[budget.id], 6000);
      expect(effective.expenseStatus[e4.id], ExpenseStatus.valid);
    });
  });

  group('expense checks', () {
    test('an expense under a rejected budget is not counted', () async {
      final (validator, investor, manager, partnershipId) =
          await setUpPartnership();
      final budget = await investor.next(
        partnership: partnershipId,
        type: 'budget_proposal',
        body: {'grantee': manager.key, 'amount': 10000},
      );
      final reject = await manager.next(
        partnership: partnershipId,
        type: 'reject',
        refersTo: budget.id,
      );
      final expense = await _expense(manager, partnershipId, budget, 4000);
      await _receiveInOrder(validator, [budget, reject, expense]);

      final effective = await _effective(validator);

      expect(
        effective.expenseStatus[expense.id],
        ExpenseStatus.noEffectiveBudget,
      );
      expect(effective.isEffective(expense), isFalse);
    });

    test(
      'an amount that is zero or negative is rejected, not stored',
      () async {
        // Fractions cannot reach this check: canonicalJson refuses doubles
        // (hard rule 1), so such a record can never be signed or verified.
        // A zero or negative amount is caught earlier now too (spec section
        // 5, schema step), so it never reaches `expenseStatus` at all.
        final (validator, investor, manager, partnershipId) =
            await setUpPartnership();
        final (budget, approve) = await _approvedBudget(
          investor,
          manager,
          partnershipId,
        );
        final zero = await _expense(manager, partnershipId, budget, 0);
        final negative = await _expense(manager, partnershipId, budget, -500);
        await _receiveInOrder(validator, [budget, approve]);

        expect(
          await validator.receiveText(canonicalJson(zero.toJson())),
          ReceiveOutcome.rejectedSchema,
        );
        expect(
          await validator.receiveText(canonicalJson(negative.toJson())),
          ReceiveOutcome.rejectedSchema,
        );

        final effective = await _effective(validator);
        expect(effective.expenseStatus.containsKey(zero.id), isFalse);
        expect(effective.expenseStatus.containsKey(negative.id), isFalse);
        expect(effective.budgetUsed[budget.id], 0);
      },
    );

    test('a zero or negative amount is still badAmount if it ever reaches the '
        'business layer some other way (defense in depth)', () async {
      // The schema check above means a real receive never gets this far.
      // This takes a validly-signed expense and corrupts its amount
      // afterwards, without sending it through the validator, to prove
      // `expenseStatus` still catches a bad amount on its own.
      final (validator, investor, manager, partnershipId) =
          await setUpPartnership();
      final (budget, approve) = await _approvedBudget(
        investor,
        manager,
        partnershipId,
      );
      await _receiveInOrder(validator, [budget, approve]);
      final zero = (await _expense(
        manager,
        partnershipId,
        budget,
        1,
      )).copyWith(body: {'amount': 0, 'receiptHash': null});

      final effective = computeEffective([
        ...validator.usableRecords,
        zero,
      ], partnershipKeys: validator.partnershipKeys!);

      expect(effective.expenseStatus[zero.id], ExpenseStatus.badAmount);
    });

    test('an expense that exactly fills the budget is valid', () async {
      final (validator, investor, manager, partnershipId) =
          await setUpPartnership();
      final (budget, approve) = await _approvedBudget(
        investor,
        manager,
        partnershipId,
      );
      final expense = await _expense(manager, partnershipId, budget, 10000);
      await _receiveInOrder(validator, [budget, approve, expense]);

      final effective = await _effective(validator);

      expect(effective.expenseStatus[expense.id], ExpenseStatus.valid);
      expect(effective.budgetUsed[budget.id], 10000);
    });
  });

  group('order independence (spec section 6.4, hard rule 5)', () {
    test(
      'the same records in different arrival orders give the same budget result',
      () async {
        final (first, investor, manager, partnershipId) =
            await setUpPartnership();
        final create = first.usableRecords.singleWhere(
          (r) => r.type == 'partnership_create',
        );
        final approveCreate = first.usableRecords.singleWhere(
          (r) => r.type == 'approve' && r.refersTo == create.id,
        );
        final (budget, approve) = await _approvedBudget(
          investor,
          manager,
          partnershipId,
        );
        final e1 = await _expense(manager, partnershipId, budget, 4000);
        final e2 = await _expense(manager, partnershipId, budget, 3000);
        final e3 = await _expense(manager, partnershipId, budget, 5000);
        final r2 = await investor.next(
          partnership: partnershipId,
          type: 'reversal',
          refersTo: e2.id,
        );
        final approveR2 = await manager.next(
          partnership: partnershipId,
          type: 'approve',
          refersTo: r2.id,
        );
        final e4 = await _expense(manager, partnershipId, budget, 2000);

        final orders = [
          [budget, approve, e1, e2, e3, r2, approveR2, e4],
          [e4, approveR2, r2, e3, e2, e1, approve, budget],
          [e2, budget, e4, r2, e1, approveR2, e3, approve],
        ];

        Effectiveness? baseline;
        for (final order in orders) {
          final validator = Validator.unpinnedForTesting();
          await validator.receiveText(canonicalJson(create.toJson()));
          await validator.receiveText(canonicalJson(approveCreate.toJson()));
          for (final record in order) {
            await validator.receiveText(canonicalJson(record.toJson()));
          }
          final effective = await _effective(validator);

          baseline ??= effective;
          expect(effective.expenseStatus, equals(baseline.expenseStatus));
          expect(effective.budgetUsed, equals(baseline.budgetUsed));
          expect(
            effective.effectiveIds,
            unorderedEquals(baseline.effectiveIds),
          );
        }
        expect(baseline!.budgetUsed[budget.id], 6000);
      },
    );
  });
}
