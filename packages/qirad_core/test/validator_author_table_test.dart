// Table-driven tests for spec section 5's "Allowed author" column. Our
// threat model assumes the other partner may be dishonest and can sign any
// record with their own valid key, without going through this app at all —
// so a record from the wrong role for its type must be rejected on receive
// (spec 6.1, step 3), the same as a record from an outside key. One test per
// restricted type, checking both the allowed author (accepted) and the
// disallowed one (rejectedMembership).
//
// `partnership_create`'s author rule is already enforced and tested
// elsewhere (`_matchesPins`, before `_partnershipKeys` even exists — see
// `validator_pins_test.dart`), so it is not repeated here.
import 'package:qirad_core/qirad_core.dart';
import 'package:test/test.dart';

import 'support/partnership_fixture.dart';
import 'support/test_ids.dart';

Future<ReceiveOutcome> _receive(Validator validator, Record record) =>
    validator.receiveText(canonicalJson(record.toJson()));

void main() {
  group('spec section 5 — allowed author', () {
    test('invest: investor only', () async {
      final (validator, investor, manager, partnershipId) =
          await setUpPartnership();

      final good = await investor.next(
        partnership: partnershipId,
        type: 'invest',
        body: {'amount': 1000},
      );
      expect(await _receive(validator, good), ReceiveOutcome.accepted);

      final bad = await manager.next(
        partnership: partnershipId,
        type: 'invest',
        body: {'amount': 1000},
      );
      expect(
        await _receive(validator, bad),
        ReceiveOutcome.rejectedMembership,
      );
    });

    test('sale: manager only', () async {
      final (validator, investor, manager, partnershipId) =
          await setUpPartnership();

      final good = await manager.next(
        partnership: partnershipId,
        type: 'sale',
        body: {'amount': 1000},
      );
      expect(await _receive(validator, good), ReceiveOutcome.accepted);

      final bad = await investor.next(
        partnership: partnershipId,
        type: 'sale',
        body: {'amount': 1000},
      );
      expect(
        await _receive(validator, bad),
        ReceiveOutcome.rejectedMembership,
      );
    });

    test('expense: manager only', () async {
      final (validator, investor, manager, partnershipId) =
          await setUpPartnership();

      final good = await manager.next(
        partnership: partnershipId,
        type: 'expense',
        body: {'amount': 500, 'receiptHash': null},
        refersTo: testId('budget'),
      );
      expect(await _receive(validator, good), ReceiveOutcome.accepted);

      final bad = await investor.next(
        partnership: partnershipId,
        type: 'expense',
        body: {'amount': 500, 'receiptHash': null},
        refersTo: testId('budget'),
      );
      expect(
        await _receive(validator, bad),
        ReceiveOutcome.rejectedMembership,
      );
    });

    test('settlement: manager only', () async {
      final (validator, investor, manager, partnershipId) =
          await setUpPartnership();

      final good = await manager.next(
        partnership: partnershipId,
        type: 'settlement',
        body: {
          'cut': {investor.key: 1, manager.key: 1},
        },
      );
      expect(await _receive(validator, good), ReceiveOutcome.accepted);

      final bad = await investor.next(
        partnership: partnershipId,
        type: 'settlement',
        body: {
          'cut': {investor.key: 1, manager.key: 1},
        },
      );
      expect(
        await _receive(validator, bad),
        ReceiveOutcome.rejectedMembership,
      );
    });

    test(
      'withdraw_request, kind capital: investor only '
      '(decision 2026-10-10 — the manager has no capital)',
      () async {
        final (validator, investor, manager, partnershipId) =
            await setUpPartnership();

        final good = await investor.next(
          partnership: partnershipId,
          type: 'withdraw_request',
          body: {'amount': 500, 'kind': 'capital'},
        );
        expect(await _receive(validator, good), ReceiveOutcome.accepted);

        final bad = await manager.next(
          partnership: partnershipId,
          type: 'withdraw_request',
          body: {'amount': 500, 'kind': 'capital'},
        );
        expect(
          await _receive(validator, bad),
          ReceiveOutcome.rejectedMembership,
        );
      },
    );

    test('withdraw_request, kind profit: either partner', () async {
      final (validator, investor, manager, partnershipId) =
          await setUpPartnership();

      final fromInvestor = await investor.next(
        partnership: partnershipId,
        type: 'withdraw_request',
        body: {'amount': 500, 'kind': 'profit'},
      );
      expect(
        await _receive(validator, fromInvestor),
        ReceiveOutcome.accepted,
      );

      final fromManager = await manager.next(
        partnership: partnershipId,
        type: 'withdraw_request',
        body: {'amount': 500, 'kind': 'profit'},
      );
      expect(
        await _receive(validator, fromManager),
        ReceiveOutcome.accepted,
      );
    });

    test('budget_proposal: either partner', () async {
      final (validator, investor, manager, partnershipId) =
          await setUpPartnership();

      final fromInvestor = await investor.next(
        partnership: partnershipId,
        type: 'budget_proposal',
        body: {'grantee': manager.key, 'amount': 500},
      );
      expect(
        await _receive(validator, fromInvestor),
        ReceiveOutcome.accepted,
      );

      final fromManager = await manager.next(
        partnership: partnershipId,
        type: 'budget_proposal',
        body: {'grantee': investor.key, 'amount': 500},
      );
      expect(
        await _receive(validator, fromManager),
        ReceiveOutcome.accepted,
      );
    });

    test('ratio_proposal: either partner', () async {
      final (validator, investor, manager, partnershipId) =
          await setUpPartnership();

      final fromInvestor = await investor.next(
        partnership: partnershipId,
        type: 'ratio_proposal',
        body: {
          'ratio': {'investor': 50, 'manager': 50},
          'effectiveFrom': '2026-11-01',
        },
      );
      expect(
        await _receive(validator, fromInvestor),
        ReceiveOutcome.accepted,
      );

      final fromManager = await manager.next(
        partnership: partnershipId,
        type: 'ratio_proposal',
        body: {
          'ratio': {'investor': 55, 'manager': 45},
          'effectiveFrom': '2026-12-01',
        },
      );
      expect(
        await _receive(validator, fromManager),
        ReceiveOutcome.accepted,
      );
    });

    for (final type in ['reversal', 'approve', 'reject']) {
      test('$type: either partner', () async {
        final (validator, investor, manager, partnershipId) =
            await setUpPartnership();

        final fromInvestor = await investor.next(
          partnership: partnershipId,
          type: type,
          refersTo: testId('target-a'),
        );
        expect(
          await _receive(validator, fromInvestor),
          ReceiveOutcome.accepted,
        );

        final fromManager = await manager.next(
          partnership: partnershipId,
          type: type,
          refersTo: testId('target-b'),
        );
        expect(
          await _receive(validator, fromManager),
          ReceiveOutcome.accepted,
        );
      });
    }
  });
}
