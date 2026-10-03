import 'package:qirad_core/qirad_core.dart';
import 'package:test/test.dart';

import 'support/partnership_fixture.dart';

Future<Effectiveness> _effective(Validator validator) async => computeEffective(
  validator.usableRecords,
  partnershipKeys: validator.partnershipKeys!,
);

/// Creates a record of [type] that targets something, and returns the target
/// together with the partner who wrote it. The reversal is then written by that
/// same partner, so it is an own reversal and needs no approval. The reason
/// for each type is only to produce a valid target to reverse.
Future<(Record, ChainAuthor)> _targetOfType(
  String type,
  Validator validator,
  ChainAuthor investor,
  ChainAuthor manager,
  String partnershipId,
) async {
  switch (type) {
    case 'partnership_create':
      final create = validator.usableRecords.singleWhere((r) => r.type == type);
      return (create, investor);
    case 'ratio_proposal':
      final proposal = await investor.next(
        partnership: partnershipId,
        type: type,
        body: {
          'ratio': {'investor': 60, 'manager': 40},
          'effectiveFrom': '2026-11-01',
        },
      );
      await validator.receiveText(canonicalJson(proposal.toJson()));
      return (proposal, investor);
    case 'budget_proposal':
      final budget = await investor.next(
        partnership: partnershipId,
        type: type,
        body: {'grantee': manager.key, 'amount': 10000},
      );
      await validator.receiveText(canonicalJson(budget.toJson()));
      return (budget, investor);
    case 'approve':
    case 'reject':
      final budget = await investor.next(
        partnership: partnershipId,
        type: 'budget_proposal',
        body: {'grantee': manager.key, 'amount': 10000},
      );
      final response = await manager.next(
        partnership: partnershipId,
        type: type,
        refersTo: budget.id,
      );
      await validator.receiveText(canonicalJson(budget.toJson()));
      await validator.receiveText(canonicalJson(response.toJson()));
      return (response, manager);
    case 'reversal':
      final expense = await manager.next(
        partnership: partnershipId,
        type: 'expense',
        body: {'amount': 4000, 'receiptHash': null},
      );
      final reversal = await investor.next(
        partnership: partnershipId,
        type: 'reversal',
        refersTo: expense.id,
      );
      await validator.receiveText(canonicalJson(expense.toJson()));
      await validator.receiveText(canonicalJson(reversal.toJson()));
      return (reversal, investor);
  }
  throw ArgumentError('no setup for $type');
}

void main() {
  group('own reversal (spec section 6.3)', () {
    test(
      'a partner reversing their own expense cancels it with no approval',
      () async {
        final (validator, _, manager, partnershipId) = await setUpPartnership();
        final expense = await manager.next(
          partnership: partnershipId,
          type: 'expense',
          body: {'amount': 4000, 'receiptHash': null},
        );
        final reversal = await manager.next(
          partnership: partnershipId,
          type: 'reversal',
          refersTo: expense.id,
        );
        await validator.receiveText(canonicalJson(expense.toJson()));
        await validator.receiveText(canonicalJson(reversal.toJson()));

        final effective = await _effective(validator);

        expect(effective.cancelledIds, {expense.id});
        expect(effective.isEffective(expense), isFalse);
        expect(effective.isEffective(reversal), isTrue);
        expect(effective.invalidReversals, isEmpty);
      },
    );
  });

  group("reversing the other partner's record needs approval", () {
    // The investor reverses the manager's expense, so the reversal needs the
    // manager's approve or reject.
    Future<(Validator, Record, Record, ChainAuthor, String)>
    otherPartnerSetup() async {
      final (validator, investor, manager, partnershipId) =
          await setUpPartnership();
      // The expense only counts under an approved budget (spec section 6.4).
      final budget = await investor.next(
        partnership: partnershipId,
        type: 'budget_proposal',
        body: {'grantee': manager.key, 'amount': 10000},
      );
      final budgetApprove = await manager.next(
        partnership: partnershipId,
        type: 'approve',
        refersTo: budget.id,
      );
      final expense = await manager.next(
        partnership: partnershipId,
        type: 'expense',
        body: {'amount': 4000, 'receiptHash': null},
        refersTo: budget.id,
      );
      final reversal = await investor.next(
        partnership: partnershipId,
        type: 'reversal',
        refersTo: expense.id,
      );
      await validator.receiveText(canonicalJson(budget.toJson()));
      await validator.receiveText(canonicalJson(budgetApprove.toJson()));
      await validator.receiveText(canonicalJson(expense.toJson()));
      await validator.receiveText(canonicalJson(reversal.toJson()));
      return (validator, expense, reversal, manager, partnershipId);
    }

    test(
      'without a response the reversal is pending and the expense stays effective',
      () async {
        final (validator, expense, reversal, _, _) = await otherPartnerSetup();

        final effective = await _effective(validator);

        expect(effective.isEffective(reversal), isFalse);
        expect(effective.isEffective(expense), isTrue);
        expect(effective.cancelledIds, isEmpty);
      },
    );

    test(
      'an approve from the other partner makes the reversal cancel the expense',
      () async {
        final (validator, expense, reversal, manager, partnershipId) =
            await otherPartnerSetup();
        final approve = await manager.next(
          partnership: partnershipId,
          type: 'approve',
          refersTo: reversal.id,
        );
        await validator.receiveText(canonicalJson(approve.toJson()));

        final effective = await _effective(validator);

        expect(effective.isEffective(reversal), isTrue);
        expect(effective.isEffective(expense), isFalse);
        expect(effective.cancelledIds, {expense.id});
      },
    );

    test(
      'a reject from the other partner kills the reversal, so the expense stays effective',
      () async {
        final (validator, expense, reversal, manager, partnershipId) =
            await otherPartnerSetup();
        final reject = await manager.next(
          partnership: partnershipId,
          type: 'reject',
          refersTo: reversal.id,
        );
        await validator.receiveText(canonicalJson(reject.toJson()));

        final effective = await _effective(validator);

        expect(effective.isEffective(reversal), isFalse);
        expect(effective.isEffective(expense), isTrue);
        expect(effective.cancelledIds, isEmpty);
      },
    );
  });

  group('reversal targets that are not reversible are flagged invalid', () {
    for (final type in [
      'partnership_create',
      'ratio_proposal',
      'budget_proposal',
      'approve',
      'reject',
      'reversal',
    ]) {
      test('reversing a $type is flagged, has no effect', () async {
        final (validator, investor, manager, partnershipId) =
            await setUpPartnership();
        final (target, author) = await _targetOfType(
          type,
          validator,
          investor,
          manager,
          partnershipId,
        );
        final reversal = await author.next(
          partnership: partnershipId,
          type: 'reversal',
          refersTo: target.id,
        );
        expect(
          await validator.receiveText(canonicalJson(reversal.toJson())),
          ReceiveOutcome.accepted,
        );

        final effective = await _effective(validator);

        expect(effective.invalidReversals[reversal.id], contains(type));
        expect(effective.isEffective(reversal), isFalse);
        expect(effective.cancelledIds, isNot(contains(target.id)));
      });
    }
  });

  group('reversible types can be reversed', () {
    // Each row: who writes it, its type and a valid body.
    final cases = <(String, String, Map<String, dynamic>)>[
      ('investor', 'invest', {'amount': 5000}),
      ('manager', 'sale', {'amount': 3000}),
      ('manager', 'expense', {'amount': 4000, 'receiptHash': null}),
      ('investor', 'withdraw_request', {'amount': 1000, 'kind': 'profit'}),
    ];
    for (final (writer, type, body) in cases) {
      test('an own reversal of $type is not flagged and cancels it', () async {
        final (validator, investor, manager, partnershipId) =
            await setUpPartnership();
        final author = writer == 'investor' ? investor : manager;
        final target = await author.next(
          partnership: partnershipId,
          type: type,
          body: body,
        );
        final reversal = await author.next(
          partnership: partnershipId,
          type: 'reversal',
          refersTo: target.id,
        );
        await validator.receiveText(canonicalJson(target.toJson()));
        await validator.receiveText(canonicalJson(reversal.toJson()));

        final effective = await _effective(validator);

        expect(effective.invalidReversals, isEmpty);
        expect(effective.cancelledIds, {target.id});
      });
    }
  });

  group('order independence (spec section 6.3, hard rule 5)', () {
    test(
      'a reversal that arrives before its target is neither flagged nor effective',
      () async {
        final (first, investor, manager, partnershipId) =
            await setUpPartnership();
        final expense = await manager.next(
          partnership: partnershipId,
          type: 'expense',
          body: {'amount': 4000, 'receiptHash': null},
        );
        final reversal = await investor.next(
          partnership: partnershipId,
          type: 'reversal',
          refersTo: expense.id,
        );
        // The manager's approve is needed, since the investor reversed the
        // manager's expense.
        final approve = await manager.next(
          partnership: partnershipId,
          type: 'approve',
          refersTo: reversal.id,
        );
        final create = first.usableRecords.singleWhere(
          (r) => r.type == 'partnership_create',
        );
        final validator = Validator.unpinnedForTesting();
        await validator.receiveText(canonicalJson(create.toJson()));

        // The reversal is accepted first; its target is still missing.
        expect(
          await validator.receiveText(canonicalJson(reversal.toJson())),
          ReceiveOutcome.accepted,
        );
        var effective = await _effective(validator);
        expect(effective.invalidReversals, isEmpty);
        expect(effective.isEffective(reversal), isFalse);

        // The target arrives, then the approve. The reversal now takes effect.
        await validator.receiveText(canonicalJson(expense.toJson()));
        await validator.receiveText(canonicalJson(approve.toJson()));
        effective = await _effective(validator);
        expect(effective.invalidReversals, isEmpty);
        expect(effective.cancelledIds, {expense.id});
      },
    );

    test(
      'the same records in any arrival order give the same effective set',
      () async {
        final (first, investor, manager, partnershipId) =
            await setUpPartnership();
        final create = first.usableRecords.singleWhere(
          (r) => r.type == 'partnership_create',
        );
        final expense = await manager.next(
          partnership: partnershipId,
          type: 'expense',
          body: {'amount': 4000, 'receiptHash': null},
        );
        final reversal = await investor.next(
          partnership: partnershipId,
          type: 'reversal',
          refersTo: expense.id,
        );
        final approve = await manager.next(
          partnership: partnershipId,
          type: 'approve',
          refersTo: reversal.id,
        );

        final orders = [
          [expense, reversal, approve],
          [approve, reversal, expense],
          [reversal, approve, expense],
        ];

        Effectiveness? baseline;
        for (final order in orders) {
          final validator = Validator.unpinnedForTesting();
          await validator.receiveText(canonicalJson(create.toJson()));
          for (final record in order) {
            await validator.receiveText(canonicalJson(record.toJson()));
          }
          final effective = await _effective(validator);

          baseline ??= effective;
          expect(
            effective.effectiveIds,
            unorderedEquals(baseline.effectiveIds),
          );
          expect(
            effective.cancelledIds,
            unorderedEquals(baseline.cancelledIds),
          );
          expect(effective.invalidReversals, equals(baseline.invalidReversals));
        }
        expect(baseline!.cancelledIds, {expense.id});
      },
    );
  });
}
