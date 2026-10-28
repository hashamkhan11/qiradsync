import 'package:qirad_core/qirad_core.dart';
import 'package:test/test.dart';

import 'support/partnership_fixture.dart';

void main() {
  group('proposalRefusal (spec sections 5, 6.4, 6.7)', () {
    test('invest by the investor is allowed', () async {
      final (validator, investor, manager, _) = await setUpPartnership();
      final parties = Parties(investor: investor.key, manager: manager.key);

      final result = proposalRefusal(
        type: 'invest',
        author: investor.key,
        parties: parties,
        ledger: validator.usableRecords.toList(),
        validator: validator,
        amount: 1000,
      );

      expect(result, isNull);
    });

    test('sale by the investor is refused (wrongRole)', () async {
      final (validator, investor, manager, _) = await setUpPartnership();
      final parties = Parties(investor: investor.key, manager: manager.key);

      final result = proposalRefusal(
        type: 'sale',
        author: investor.key,
        parties: parties,
        ledger: validator.usableRecords.toList(),
        validator: validator,
        amount: 1000,
      );

      expect(result?.reason, ProposalRefusal.wrongRole);
    });

    test(
      'an expense against a budget nobody granted is refused '
      '(noEffectiveBudget)',
      () async {
        final (validator, investor, manager, _) = await setUpPartnership();
        final parties = Parties(investor: investor.key, manager: manager.key);

        final result = proposalRefusal(
          type: 'expense',
          author: manager.key,
          parties: parties,
          ledger: validator.usableRecords.toList(),
          validator: validator,
          budgetId: 'no-such-budget',
          amount: 1000,
        );

        expect(result?.reason, ProposalRefusal.noEffectiveBudget);
      },
    );

    test(
      'an expense within an effective budget is allowed, and lowers what '
      'is left',
      () async {
        final (validator, investor, manager, partnership) =
            await setUpPartnership();
        final parties = Parties(investor: investor.key, manager: manager.key);

        final budget = await investor.next(
          partnership: partnership,
          type: 'budget_proposal',
          body: {'grantee': manager.key, 'amount': 5000},
        );
        final approve = await manager.next(
          partnership: partnership,
          type: 'approve',
          refersTo: budget.id,
        );
        await validator.receiveText(canonicalJson(budget.toJson()));
        await validator.receiveText(canonicalJson(approve.toJson()));

        final result = proposalRefusal(
          type: 'expense',
          author: manager.key,
          parties: parties,
          ledger: validator.usableRecords.toList(),
          validator: validator,
          budgetId: budget.id,
          amount: 2000,
        );

        expect(result, isNull);
      },
    );

    test(
      'an expense for more than what is left is refused (overBudget), and '
      'carries the amount actually left',
      () async {
        final (validator, investor, manager, partnership) =
            await setUpPartnership();
        final parties = Parties(investor: investor.key, manager: manager.key);

        final budget = await investor.next(
          partnership: partnership,
          type: 'budget_proposal',
          body: {'grantee': manager.key, 'amount': 2000},
        );
        final approve = await manager.next(
          partnership: partnership,
          type: 'approve',
          refersTo: budget.id,
        );
        await validator.receiveText(canonicalJson(budget.toJson()));
        await validator.receiveText(canonicalJson(approve.toJson()));

        final result = proposalRefusal(
          type: 'expense',
          author: manager.key,
          parties: parties,
          ledger: validator.usableRecords.toList(),
          validator: validator,
          budgetId: budget.id,
          amount: 3000,
        );

        expect(result?.reason, ProposalRefusal.overBudget);
        expect(result?.budgetLeft, 2000);
      },
    );

    test(
      'reversing a type spec section 5 never allows is refused '
      '(notReversible)',
      () async {
        final (validator, investor, manager, partnership) =
            await setUpPartnership();
        final parties = Parties(investor: investor.key, manager: manager.key);
        final create = validator.usableRecords.singleWhere(
          (r) => r.type == 'partnership_create',
        );

        final result = proposalRefusal(
          type: 'reversal',
          author: investor.key,
          parties: parties,
          ledger: validator.usableRecords.toList(),
          validator: validator,
          reversalTarget: create.id,
        );

        expect(result?.reason, ProposalRefusal.notReversible);
      },
    );

    test('reversing a target this phone never held is notReversible', () async {
      final (validator, investor, manager, _) = await setUpPartnership();
      final parties = Parties(investor: investor.key, manager: manager.key);

      final result = proposalRefusal(
        type: 'reversal',
        author: investor.key,
        parties: parties,
        ledger: validator.usableRecords.toList(),
        validator: validator,
        reversalTarget: 'no-such-record',
      );

      expect(result?.reason, ProposalRefusal.notReversible);
    });

    test('reversing an invest is allowed', () async {
      final (validator, investor, manager, partnership) =
          await setUpPartnership();
      final parties = Parties(investor: investor.key, manager: manager.key);
      final invest = await investor.next(
        partnership: partnership,
        type: 'invest',
        body: {'amount': 1000},
      );
      await validator.receiveText(canonicalJson(invest.toJson()));

      final result = proposalRefusal(
        type: 'reversal',
        author: manager.key,
        parties: parties,
        ledger: validator.usableRecords.toList(),
        validator: validator,
        reversalTarget: invest.id,
      );

      expect(result, isNull);
    });

    test(
      'a settlement with nothing new since the last one is refused '
      '(emptyCut)',
      () async {
        final (validator, investor, manager, partnership) =
            await setUpPartnership();
        final parties = Parties(investor: investor.key, manager: manager.key);

        // S1 covers the create and the manager's approve of it — that is
        // new business the first time, so S1 itself is allowed.
        final s1 = await manager.next(
          partnership: partnership,
          type: 'settlement',
          body: {
            'cut': {investor.key: 1, manager.key: 1},
          },
        );
        await validator.receiveText(canonicalJson(s1.toJson()));
        final approveS1 = await investor.next(
          partnership: partnership,
          type: 'approve',
          refersTo: s1.id,
        );
        await validator.receiveText(canonicalJson(approveS1.toJson()));

        // Nothing has happened for either partner since S1 closed, so a
        // second settlement now would cover only settlement bookkeeping.
        final result = proposalRefusal(
          type: 'settlement',
          author: manager.key,
          parties: parties,
          ledger: validator.usableRecords.toList(),
          validator: validator,
        );

        expect(result?.reason, ProposalRefusal.emptyCut);
      },
    );

    test(
      'a capital withdrawal for more than current capital is refused '
      '(overCapital), and carries the amount actually left',
      () async {
        final (validator, investor, manager, partnership) =
            await setUpPartnership();
        final parties = Parties(investor: investor.key, manager: manager.key);
        final invest = await investor.next(
          partnership: partnership,
          type: 'invest',
          body: {'amount': 1000},
        );
        await validator.receiveText(canonicalJson(invest.toJson()));

        final result = proposalRefusal(
          type: 'withdraw_request',
          author: investor.key,
          parties: parties,
          ledger: validator.usableRecords.toList(),
          validator: validator,
          kind: 'capital',
          amount: 1500,
        );

        expect(result?.reason, ProposalRefusal.overCapital);
        expect(result?.capitalLeft, 1000);
      },
    );

    test(
      'a capital withdrawal within current capital is allowed',
      () async {
        final (validator, investor, manager, partnership) =
            await setUpPartnership();
        final parties = Parties(investor: investor.key, manager: manager.key);
        final invest = await investor.next(
          partnership: partnership,
          type: 'invest',
          body: {'amount': 1000},
        );
        await validator.receiveText(canonicalJson(invest.toJson()));

        final result = proposalRefusal(
          type: 'withdraw_request',
          author: investor.key,
          parties: parties,
          ledger: validator.usableRecords.toList(),
          validator: validator,
          kind: 'capital',
          amount: 1000,
        );

        expect(result, isNull);
      },
    );

    test(
      'a profit withdrawal is never refused by the capital check, even past '
      'what capital would allow',
      () async {
        final (validator, investor, manager, partnership) =
            await setUpPartnership();
        final parties = Parties(investor: investor.key, manager: manager.key);
        final invest = await investor.next(
          partnership: partnership,
          type: 'invest',
          body: {'amount': 1000},
        );
        await validator.receiveText(canonicalJson(invest.toJson()));
        final sale = await manager.next(
          partnership: partnership,
          type: 'sale',
          body: {'amount': 5000},
        );
        await validator.receiveText(canonicalJson(sale.toJson()));

        final result = proposalRefusal(
          type: 'withdraw_request',
          author: manager.key,
          parties: parties,
          ledger: validator.usableRecords.toList(),
          validator: validator,
          kind: 'profit',
          amount: 5000,
        );

        expect(result, isNull);
      },
    );

    test('a settlement covering a sale since the last one is allowed', () async {
      final (validator, investor, manager, partnership) =
          await setUpPartnership();
      final parties = Parties(investor: investor.key, manager: manager.key);
      final sale = await manager.next(
        partnership: partnership,
        type: 'sale',
        body: {'amount': 1000},
      );
      await validator.receiveText(canonicalJson(sale.toJson()));

      final result = proposalRefusal(
        type: 'settlement',
        author: manager.key,
        parties: parties,
        ledger: validator.usableRecords.toList(),
        validator: validator,
      );

      expect(result, isNull);
    });
  });
}
