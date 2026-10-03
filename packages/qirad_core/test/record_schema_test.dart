import 'package:qirad_core/qirad_core.dart';
import 'package:test/test.dart';

import 'support/partnership_fixture.dart';

void main() {
  group(
    'record schema refuses unknown keys and types (spec 3, 5, 6.1 step 1)',
    () {
      test('an unknown top-level key is refused', () async {
        final (validator, investor, _, partnershipId) =
            await setUpPartnership();
        final record = await investor.next(
          partnership: partnershipId,
          type: 'invest',
          body: {'amount': 5000},
        );
        // The signature is not checked here: step 1 runs first and refuses it.
        final withExtra = record.toJson()..['extra'] = 'not in the spec';

        expect(
          await validator.receive(withExtra),
          ReceiveOutcome.rejectedSchema,
        );
      });

      test(
        'an unknown key inside body is refused, even with a valid signature',
        () async {
          final (validator, investor, _, partnershipId) =
              await setUpPartnership();
          final record = await investor.next(
            partnership: partnershipId,
            type: 'invest',
            body: {'amount': 5000, 'receiptHash': 'not allowed on invest'},
          );

          expect(
            await validator.receive(record.toJson()),
            ReceiveOutcome.rejectedSchema,
          );
        },
      );

      test('a record type that is not in spec section 5 is refused', () async {
        final (validator, investor, _, partnershipId) =
            await setUpPartnership();
        final record = await investor.next(
          partnership: partnershipId,
          type: 'note',
        );

        expect(
          await validator.receive(record.toJson()),
          ReceiveOutcome.rejectedSchema,
        );
      });

      test('an extra key inside the ratio object is refused', () async {
        final (validator, investor, _, partnershipId) =
            await setUpPartnership();
        final proposal = await investor.next(
          partnership: partnershipId,
          type: 'ratio_proposal',
          body: {
            'ratio': {'investor': 50, 'manager': 50, 'extra': 0},
            'effectiveFrom': '2026-11-01',
          },
        );

        expect(
          await validator.receive(proposal.toJson()),
          ReceiveOutcome.rejectedSchema,
        );
      });

      test('the keys a type allows are accepted', () async {
        final (validator, investor, _, partnershipId) =
            await setUpPartnership();
        final expense = await investor.next(
          partnership: partnershipId,
          type: 'expense',
          body: {'amount': 500, 'receiptHash': null},
        );

        // The investor cannot write an expense (spec 5), but step 1 only checks
        // shape. The record is stored as evidence, and the rules in Phase 4 make
        // it have no effect.
        expect(
          await validator.receive(expense.toJson()),
          ReceiveOutcome.accepted,
        );
      });
    },
  );
}
