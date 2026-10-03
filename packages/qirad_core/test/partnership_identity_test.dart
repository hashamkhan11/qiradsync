import 'package:qirad_core/qirad_core.dart';
import 'package:test/test.dart';

import 'support/partnership_fixture.dart';

void main() {
  group('one partnership per ledger (decision 2026-10-03)', () {
    test(
      'a partnership_create whose partnership is not its own id is rejected',
      () async {
        final investor = ChainAuthor(await generateEd25519KeyPair());
        final manager = ChainAuthor(await generateEd25519KeyPair());
        final validator = Validator();
        final create = await investor.next(
          partnership: 'partnership-1',
          type: 'partnership_create',
          id: 'some-other-id',
          body: {
            'investor': investor.key,
            'manager': manager.key,
            'ratio': {'investor': 60, 'manager': 40},
            'currency': 'PKR',
          },
        );

        expect(
          await validator.receiveText(canonicalJson(create.toJson())),
          ReceiveOutcome.rejectedSchema,
        );
        expect(validator.partnershipKeys, isNull);
      },
    );

    test('a second partnership_create is rejected and never stored', () async {
      final (validator, investor, manager, _) = await setUpPartnership();
      final second = await investor.next(
        partnership: 'partnership-2',
        type: 'partnership_create',
        id: 'partnership-2',
        body: {
          'investor': investor.key,
          'manager': manager.key,
          'ratio': {'investor': 50, 'manager': 50},
          'currency': 'PKR',
        },
      );

      expect(
        await validator.receiveText(canonicalJson(second.toJson())),
        ReceiveOutcome.rejectedMembership,
      );
      expect(
        validator.ledger.records.where((r) => r.type == 'partnership_create'),
        hasLength(1),
      );
    });

    test(
      'a record for another partnership is rejected, even from a partner',
      () async {
        final (validator, investor, _, _) = await setUpPartnership();
        final stray = await investor.next(
          partnership: 'partnership-2',
          type: 'invest',
          body: {'amount': 100},
        );

        expect(
          await validator.receiveText(canonicalJson(stray.toJson())),
          ReceiveOutcome.rejectedMembership,
        );
      },
    );

    test('a record for this partnership is still accepted', () async {
      final (validator, investor, _, partnershipId) = await setUpPartnership();
      final invest = await investor.next(
        partnership: partnershipId,
        type: 'invest',
        body: {'amount': 100},
      );

      expect(await validator.receiveText(canonicalJson(invest.toJson())), ReceiveOutcome.accepted);
    });

    test(
      'after a partnership is rejected, a new one starts again at seq 1',
      () async {
        // The retry path: a new create is a new partnership with its own ledger.
        // Each partner's seq starts at 1 in it (spec section 3).
        final investor = ChainAuthor(await generateEd25519KeyPair());
        final manager = ChainAuthor(await generateEd25519KeyPair());
        final create = await investor.next(
          partnership: 'partnership-new',
          type: 'partnership_create',
          id: 'partnership-new',
          body: {
            'investor': investor.key,
            'manager': manager.key,
            'ratio': {'investor': 60, 'manager': 40},
            'currency': 'PKR',
          },
        );

        expect(create.seq, 1);
        expect(
          await Validator().receiveText(canonicalJson(create.toJson())),
          ReceiveOutcome.accepted,
        );
      },
    );
  });
}
