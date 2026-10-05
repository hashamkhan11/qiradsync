import 'package:qirad_core/qirad_core.dart';
import 'package:test/test.dart';

import 'support/partnership_fixture.dart';
import 'support/test_ids.dart';

void main() {
  // These records skip the validator on purpose, to check that the period code
  // is safe even when it is handed bad input (decision Q3b).
  group('period code with bad input does not crash', () {
    test(
      'a create with a ratio that does not sum to 100 gives no periods',
      () async {
        final investor = ChainAuthor(await generateEd25519KeyPair());
        final manager = ChainAuthor(await generateEd25519KeyPair());
        final id = testId('partnership-bad-ratio');
        final create = await investor.next(
          partnership: id,
          type: 'partnership_create',
          id: id,
          body: {
            'investor': investor.key,
            'manager': manager.key,
            'ratio': {'investor': 60, 'manager': 50},
          },
        );
        final sale = await manager.next(
          partnership: id,
          type: 'sale',
          body: {'amount': 600},
        );

        final periods = periodShares(
          [create, sale],
          partnershipKeys: {investor.key, manager.key},
        );
        expect(periods, isEmpty);
      },
    );

    test('records with no create at all give no periods', () async {
      final manager = ChainAuthor(await generateEd25519KeyPair());
      final sale = await manager.next(
        partnership: testId('partnership-no-create'),
        type: 'sale',
        body: {'amount': 600},
      );

      final periods = periodShares([sale], partnershipKeys: {manager.key});
      expect(periods, isEmpty);
    });
  });
}
