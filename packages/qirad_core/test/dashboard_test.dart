import 'package:qirad_core/qirad_core.dart';
import 'package:test/test.dart';

import 'support/partnership_fixture.dart';

Future<Dashboard> _dashboard(Validator validator) async {
  return buildDashboard(
    validator.usableRecords,
    partnershipKeys: validator.partnershipKeys!,
  );
}

Future<void> _receiveInOrder(Validator validator, List<Record> records) async {
  for (final record in records) {
    expect(
      await validator.receiveText(canonicalJson(record.toJson())),
      ReceiveOutcome.accepted,
      reason: record.id,
    );
  }
}

/// The manager approves the investor's create. Until then the partnership is
/// not effective, so it has no ratio (spec 6.3, 6.6).
Future<Record> _approveCreate(
  Validator validator,
  ChainAuthor manager,
  String partnershipId,
) async {
  final create = validator.usableRecords.singleWhere(
    (r) => r.type == 'partnership_create',
  );
  return manager.next(
    partnership: partnershipId,
    type: 'approve',
    refersTo: create.id,
  );
}

void main() {
  group('dashboard (spec sections 6.5 and 6.6)', () {
    test('a profit gives the money totals and each partner\'s share', () async {
      final (validator, investor, manager, partnershipId) =
          await setUpPartnership();
      // Approved first, so the manager's chain has it at seq 1 (spec 6.1).
      final approveCreate = await _approveCreate(
        validator,
        manager,
        partnershipId,
      );
      // Paisa: 10,000 invested, 3,000 sold, 1,000 spent on an approved budget.
      final invest = await investor.next(
        partnership: partnershipId,
        type: 'invest',
        body: {'amount': 1000000},
      );
      final budget = await investor.next(
        partnership: partnershipId,
        type: 'budget_proposal',
        body: {'grantee': manager.key, 'amount': 500000},
      );
      final approveBudget = await manager.next(
        partnership: partnershipId,
        type: 'approve',
        refersTo: budget.id,
      );
      final sale = await manager.next(
        partnership: partnershipId,
        type: 'sale',
        body: {'amount': 300000},
      );
      final expense = await manager.next(
        partnership: partnershipId,
        type: 'expense',
        body: {'amount': 100000, 'receiptHash': null},
        refersTo: budget.id,
      );
      await _receiveInOrder(validator, [
        approveCreate,
        invest,
        budget,
        approveBudget,
        sale,
        expense,
      ]);

      final dashboard = await _dashboard(validator);

      expect(dashboard.money.capital, 1000000);
      expect(dashboard.money.cashBalance, 1200000);
      expect(dashboard.money.result, 200000);
      expect(dashboard.ratio?.ratio, const Ratio(investor: 60, manager: 40));
      // Manager: 200000 * 40 / 100 = 80000. The investor takes the rest.
      expect(dashboard.shares!.manager, 80000);
      expect(dashboard.shares!.investor, 120000);
    });

    test('a loss is carried by the investor, and the manager gets 0', () async {
      final (validator, investor, manager, partnershipId) =
          await setUpPartnership();
      // Approved first, so the manager's chain has it at seq 1 (spec 6.1).
      final approveCreate = await _approveCreate(
        validator,
        manager,
        partnershipId,
      );
      final invest = await investor.next(
        partnership: partnershipId,
        type: 'invest',
        body: {'amount': 1000000},
      );
      final budget = await investor.next(
        partnership: partnershipId,
        type: 'budget_proposal',
        body: {'grantee': manager.key, 'amount': 500000},
      );
      final approveBudget = await manager.next(
        partnership: partnershipId,
        type: 'approve',
        refersTo: budget.id,
      );
      final sale = await manager.next(
        partnership: partnershipId,
        type: 'sale',
        body: {'amount': 100000},
      );
      final expense = await manager.next(
        partnership: partnershipId,
        type: 'expense',
        body: {'amount': 300000, 'receiptHash': null},
        refersTo: budget.id,
      );
      await _receiveInOrder(validator, [
        approveCreate,
        invest,
        budget,
        approveBudget,
        sale,
        expense,
      ]);

      final dashboard = await _dashboard(validator);

      expect(dashboard.money.result, -200000);
      expect(dashboard.shares!.investor, -200000);
      expect(dashboard.shares!.manager, 0);
    });

    test('the latest proposal sets the split for all the result', () async {
      final (validator, investor, manager, partnershipId) =
          await setUpPartnership();
      // Approved first, so the manager's chain has it at seq 1 (spec 6.1).
      final approveCreate = await _approveCreate(
        validator,
        manager,
        partnershipId,
      );
      final sale = await manager.next(
        partnership: partnershipId,
        type: 'sale',
        body: {'amount': 100000},
      );
      final proposal = await investor.next(
        partnership: partnershipId,
        type: 'ratio_proposal',
        body: {
          'ratio': {'investor': 50, 'manager': 50},
          'effectiveFrom': '2026-09-01',
        },
      );
      final approve = await manager.next(
        partnership: partnershipId,
        type: 'approve',
        refersTo: proposal.id,
      );
      await _receiveInOrder(validator, [
        approveCreate,
        sale,
        proposal,
        approve,
      ]);

      final dashboard = await _dashboard(validator);
      expect(dashboard.ratio?.ratio, const Ratio(investor: 50, manager: 50));
      expect(dashboard.ratio?.agreedStart, '2026-09-01');
      expect(dashboard.shares!.manager, 50000);
      expect(dashboard.shares!.investor, 50000);
    });

    test('an unapproved create gives no ratio and no shares', () async {
      final (validator, investor, _, partnershipId) = await setUpPartnership();
      final invest = await investor.next(
        partnership: partnershipId,
        type: 'invest',
        body: {'amount': 1000000},
      );
      await _receiveInOrder(validator, [invest]);

      final dashboard = await _dashboard(validator);

      expect(dashboard.money.capital, 1000000);
      expect(dashboard.ratio, isNull);
      expect(dashboard.shares, isNull);
    });
    group('ratio change flag and known issue (docs/decisions.md, 2026-10-05)', () {
      /// A sale of 200000 paisa, then a 50/50 ratio change from [effectiveFrom].
      Future<Validator> saleThenRatioChange(String effectiveFrom) async {
        final (validator, investor, manager, partnershipId) =
            await setUpPartnership();
        final approveCreate = await _approveCreate(
          validator,
          manager,
          partnershipId,
        );
        final sale = await manager.next(
          partnership: partnershipId,
          type: 'sale',
          body: {'amount': 200000},
        );
        final proposal = await investor.next(
          partnership: partnershipId,
          type: 'ratio_proposal',
          body: {
            'ratio': {'investor': 50, 'manager': 50},
            'effectiveFrom': effectiveFrom,
          },
        );
        final approve = await manager.next(
          partnership: partnershipId,
          type: 'approve',
          refersTo: proposal.id,
        );
        await _receiveInOrder(validator, [
          approveCreate,
          sale,
          proposal,
          approve,
        ]);
        return validator;
      }

      test('the flag is set once a ratio change has taken effect', () async {
        final validator = await saleThenRatioChange('2026-09-01');

        expect((await _dashboard(validator)).ratioChanged, isTrue);
      });

      test('a change agreed for a later date is already in force', () async {
        final validator = await saleThenRatioChange('2026-11-01');

        final dashboard = await _dashboard(validator);
        expect(dashboard.ratioChanged, isTrue);
        expect(dashboard.shares!.manager, 100000);
        expect(dashboard.ratio?.agreedStart, '2026-11-01');
      });

      test('KNOWN ISSUE: profit earned before a change is re-split at the new '
          'ratio', () async {
        // Spec 6.6 says the old ratio should keep 200000 at 60/40, so the manager
        // should get 80000. Today the whole result uses the 50/50 ratio, so the
        // manager gets 100000. When settlement is built, this expectation must
        // change to 80000 and the test must be updated.
        final validator = await saleThenRatioChange('2026-09-01');

        final dashboard = await _dashboard(validator);

        expect(dashboard.shares!.manager, 100000);
        expect(dashboard.ratioChanged, isTrue);
      });
    });
  });
}
