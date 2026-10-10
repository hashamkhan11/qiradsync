import 'package:qirad_core/qirad_core.dart';
import 'package:test/test.dart';

import 'support/partnership_fixture.dart';
import 'support/test_ids.dart';

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
          await validator.receiveText(canonicalJson(withExtra)),
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
            await validator.receiveText(canonicalJson(record.toJson())),
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
          await validator.receiveText(canonicalJson(record.toJson())),
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
          await validator.receiveText(canonicalJson(proposal.toJson())),
          ReceiveOutcome.rejectedSchema,
        );
      });

      test('the keys a type allows are accepted', () async {
        final (validator, _, manager, partnershipId) =
            await setUpPartnership();
        final expense = await manager.next(
          partnership: partnershipId,
          type: 'expense',
          body: {'amount': 500, 'receiptHash': null},
          refersTo: testId('dummy-budget'),
        );

        expect(
          await validator.receiveText(canonicalJson(expense.toJson())),
          ReceiveOutcome.accepted,
        );
      });
    },
  );

  group('each ratio share is 1 to 99 (spec section 5)', () {
    Future<ReceiveOutcome> proposeRatio(int investor, int manager) async {
      final (validator, author, _, partnershipId) = await setUpPartnership();
      final proposal = await author.next(
        partnership: partnershipId,
        type: 'ratio_proposal',
        body: {
          'ratio': {'investor': investor, 'manager': manager},
          'effectiveFrom': '2026-11-01',
        },
      );
      return validator.receiveText(canonicalJson(proposal.toJson()));
    }

    test('0 and 100 are refused, as a share for either partner', () async {
      expect(await proposeRatio(0, 100), ReceiveOutcome.rejectedSchema);
      expect(await proposeRatio(100, 0), ReceiveOutcome.rejectedSchema);
    });

    test('1 and 99 are the smallest and largest allowed shares', () async {
      expect(await proposeRatio(1, 99), isNot(ReceiveOutcome.rejectedSchema));
      expect(await proposeRatio(99, 1), isNot(ReceiveOutcome.rejectedSchema));
    });
  });

  group('record id must be a lowercase UUID v4 (spec section 3)', () {
    Future<ReceiveOutcome> receiveWithId(String id) async {
      final (validator, investor, _, partnershipId) = await setUpPartnership();
      final record = await investor.next(
        partnership: partnershipId,
        type: 'invest',
        body: {'amount': 5000},
        id: id,
      );
      return validator.receiveText(canonicalJson(record.toJson()));
    }

    test('a lowercase UUID v4 is accepted', () async {
      expect(
        await receiveWithId('3f2a9c1e-7b4d-4e8a-9c2f-1d6b5a4e3f20'),
        ReceiveOutcome.accepted,
      );
    });

    test('an uppercase UUID is refused', () async {
      expect(
        await receiveWithId('3F2A9C1E-7B4D-4E8A-9C2F-1D6B5A4E3F20'),
        ReceiveOutcome.rejectedSchema,
      );
    });

    test('a UUID of another version (1) is refused', () async {
      expect(
        await receiveWithId('3f2a9c1e-7b4d-1e8a-9c2f-1d6b5a4e3f20'),
        ReceiveOutcome.rejectedSchema,
      );
    });

    test('a UUID with the wrong variant (c) is refused', () async {
      expect(
        await receiveWithId('3f2a9c1e-7b4d-4e8a-cc2f-1d6b5a4e3f20'),
        ReceiveOutcome.rejectedSchema,
      );
    });

    test('text that is not a UUID is refused', () async {
      expect(await receiveWithId('invest-2'), ReceiveOutcome.rejectedSchema);
      expect(
        await receiveWithId('3f2a9c1e-7b4d-4e8a-9c2f-1d6b5a4e3f2'),
        ReceiveOutcome.rejectedSchema,
      );
    });
  });
}
