import 'dart:convert';

import 'package:qirad_core/qirad_core.dart';
import 'package:test/test.dart';

import 'support/partnership_fixture.dart';

void main() {
  group('canonical form on receive (spec 6.1, step 1)', () {
    test('the canonical text of a valid record is accepted', () async {
      final (validator, investor, _, partnershipId) = await setUpPartnership();
      final record = await investor.next(
        partnership: partnershipId,
        type: 'invest',
        body: {'amount': 5000},
      );

      final outcome = await validator.receiveText(
        canonicalJson(record.toJson()),
      );

      expect(outcome, ReceiveOutcome.accepted);
    });

    test('extra whitespace is refused', () async {
      final (validator, investor, _, partnershipId) = await setUpPartnership();
      final record = await investor.next(
        partnership: partnershipId,
        type: 'invest',
        body: {'amount': 5000},
      );
      final text = canonicalJson(record.toJson());

      final outcome = await validator.receiveText(' $text');

      expect(outcome, ReceiveOutcome.rejectedNotCanonical);
      expect(
        validator.ledger.records,
        hasLength(2),
        reason: 'only the create and its approval',
      );
    });

    test(
      'keys in the wrong order are refused, though the JSON is valid',
      () async {
        final (validator, investor, _, partnershipId) =
            await setUpPartnership();
        final record = await investor.next(
          partnership: partnershipId,
          type: 'invest',
          body: {'amount': 5000},
        );
        // dart:convert keeps insertion order, which is not sorted order.
        final unsorted = jsonEncode(record.toJson());

        expect(
          await validator.receiveText(unsorted),
          ReceiveOutcome.rejectedNotCanonical,
        );
        expect(
          validator.ledger.records,
          hasLength(2),
          reason: 'only the create and its approval',
        );
      },
    );

    test('a duplicate key is refused, even with the same value', () async {
      final (validator, investor, _, partnershipId) = await setUpPartnership();
      final record = await investor.next(
        partnership: partnershipId,
        type: 'invest',
        body: {'amount': 5000},
      );
      final text = canonicalJson(record.toJson());
      // jsonDecode keeps one of two equal "note" keys, so the parsed map looks
      // fine. Only the byte comparison can see the duplicate.
      final withDuplicate = '{"note":"","note":"",${text.substring(1)}';

      final outcome = await validator.receiveText(withDuplicate);

      expect(outcome, ReceiveOutcome.rejectedNotCanonical);
      expect(
        validator.ledger.records,
        hasLength(2),
        reason: 'only the create and its approval',
      );
    });

    test('an empty array where the body object belongs is refused', () async {
      final (validator, investor, _, partnershipId) = await setUpPartnership();
      final record = await investor.next(
        partnership: partnershipId,
        type: 'invest',
        body: {'amount': 5000},
      );
      // "body":[] is canonical text, but body must be an object (spec 3).
      final emptyArray = canonicalJson(record.toJson()..['body'] = []);

      final outcome = await validator.receiveText(emptyArray);

      expect(outcome, ReceiveOutcome.rejectedSchema);
      expect(
        validator.ledger.records,
        hasLength(2),
        reason: 'only the create and its approval',
      );
    });

    test('text that is not JSON is refused as a schema error', () async {
      final validator = Validator.unpinnedForTesting();

      expect(
        await validator.receiveText('not json'),
        ReceiveOutcome.rejectedSchema,
      );
    });

    test(
      'a float in the text is refused, since canonical JSON has none',
      () async {
        final validator = Validator.unpinnedForTesting();

        expect(
          await validator.receiveText('{"amount":1.5}'),
          ReceiveOutcome.rejectedNotCanonical,
        );
      },
    );
  });
}
