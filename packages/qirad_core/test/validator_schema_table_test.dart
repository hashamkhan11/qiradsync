// Table-driven tests for every rule spec sections 3 and 5 state about a
// record's shape: the record-level field formats (section 3) and each
// type's `body` and `refersTo` rules (section 5). Each test builds one
// correctly-signed record, then checks a list of broken variants of it.
//
// Schema checks run before the signature is ever verified (spec 6.1, step 1
// before step 2), so a variant with a body or `refersTo` edited after signing
// still reaches the schema check first. Its signature no longer matches, but
// that never matters here: the record is refused for being malformed before
// anyone asks whether it was signed. This is why every bad variant below can
// be built with `copyWith` on one already-signed base record.
import 'package:qirad_core/qirad_core.dart';
import 'package:test/test.dart';

import 'support/partnership_fixture.dart';
import 'support/test_ids.dart';

Future<ReceiveOutcome> _receive(Validator validator, Record record) =>
    validator.receiveText(canonicalJson(record.toJson()));

/// A copy of [record] with `refersTo` set to `null`. `Record.copyWith` cannot
/// do this itself: it uses `refersTo ?? this.refersTo`, so passing `null`
/// there just keeps the old value. Going through JSON sidesteps that.
Record _withNullRefersTo(Record record) =>
    Record.fromJson(record.toJson()..['refersTo'] = null);

/// Checks every entry in [badVariants] is rejected at the schema step, with
/// the map key as the failure reason shown if one unexpectedly is not.
Future<void> _expectAllRejected(
  Validator validator,
  Map<String, Record> badVariants,
) async {
  for (final entry in badVariants.entries) {
    expect(
      await _receive(validator, entry.value),
      ReceiveOutcome.rejectedSchema,
      reason: entry.key,
    );
  }
}

void main() {
  group('spec section 3 — record field formats', () {
    test('prevHash must be exactly 64 lowercase hex characters', () async {
      final (validator, investor, _, partnershipId) = await setUpPartnership();
      final good = await investor.next(
        partnership: partnershipId,
        type: 'invest',
        body: {'amount': 1000},
      );
      expect(await _receive(validator, good), ReceiveOutcome.accepted);

      await _expectAllRejected(validator, {
        'not hex at all': good.copyWith(prevHash: 'g' * 64),
        'uppercase is a different spelling': good.copyWith(prevHash: 'A' * 64),
        'one character short': good.copyWith(prevHash: '0' * 63),
        'one character long': good.copyWith(prevHash: '0' * 65),
      });
    });

    test(
      'time must be an ISO 8601 UTC string, in the one shape every device writes',
      () async {
        final (validator, investor, _, partnershipId) =
            await setUpPartnership();
        final good = await investor.next(
          partnership: partnershipId,
          type: 'invest',
          body: {'amount': 1000},
        );
        expect(await _receive(validator, good), ReceiveOutcome.accepted);

        await _expectAllRejected(validator, {
          'a space instead of T': good.copyWith(time: '2026-10-02 10:00:00Z'),
          'missing the Z': good.copyWith(time: '2026-10-02T10:00:00'),
          'an offset instead of Z': good.copyWith(
            time: '2026-10-02T10:00:00+05:00',
          ),
          'fractional seconds': good.copyWith(time: '2026-10-02T10:00:00.000Z'),
          'not a date at all': good.copyWith(time: 'not a date'),
        });
      },
    );

    test(
      'sig must be base64url with no padding, decoding to exactly 64 bytes',
      () async {
        final (validator, investor, _, partnershipId) =
            await setUpPartnership();
        final good = await investor.next(
          partnership: partnershipId,
          type: 'invest',
          body: {'amount': 1000},
        );
        expect(await _receive(validator, good), ReceiveOutcome.accepted);

        await _expectAllRejected(validator, {
          'one character short (85)': good.copyWith(sig: 'A' * 85),
          'one character long (87)': good.copyWith(sig: 'A' * 87),
          'right length, but not in the base64url alphabet': good.copyWith(
            sig: '${'A' * 85}!',
          ),
          'right length, but ends in padding': good.copyWith(
            sig: '${'A' * 85}=',
          ),
          'empty': good.copyWith(sig: ''),
        });
      },
    );
  });

  group('spec section 5 — partnership_create', () {
    test('refersTo, parties, ratio and currency are all checked', () async {
      final investor = ChainAuthor(await generateEd25519KeyPair());
      final manager = ChainAuthor(await generateEd25519KeyPair());
      final partnershipId = testId('schema-table-create');
      final validator = Validator.unpinnedForTesting();
      final good = await investor.next(
        partnership: partnershipId,
        type: 'partnership_create',
        id: partnershipId,
        body: {
          'investor': investor.key,
          'manager': manager.key,
          'ratio': {'investor': 60, 'manager': 40},
          'currency': 'PKR',
        },
      );
      expect(await _receive(validator, good), ReceiveOutcome.accepted);

      await _expectAllRejected(validator, {
        'refersTo must be null (spec 3)': good.copyWith(refersTo: testId('x')),
        "partnership must equal the create's own id (spec 3)": good.copyWith(
          partnership: testId('a-different-partnership'),
        ),
        'investor and manager cannot be the same key': good.copyWith(
          body: {...good.body, 'manager': investor.key},
        ),
        'investor key is not a canonical public key': good.copyWith(
          body: {...good.body, 'investor': 'not-a-key'},
        ),
        'manager key is not a canonical public key': good.copyWith(
          body: {...good.body, 'manager': 'not-a-key'},
        ),
        'currency is not PKR': good.copyWith(
          body: {...good.body, 'currency': 'USD'},
        ),
        'a ratio share of 0 is out of range': good.copyWith(
          body: {
            ...good.body,
            'ratio': {'investor': 0, 'manager': 100},
          },
        ),
        'a ratio that does not add up to 100': good.copyWith(
          body: {
            ...good.body,
            'ratio': {'investor': 70, 'manager': 20},
          },
        ),
      });
    });
  });

  group('spec section 5 — invest and sale', () {
    for (final type in ['invest', 'sale']) {
      test(
        '$type: refersTo must be null, amount must be a positive integer',
        () async {
          final (validator, investor, _, partnershipId) =
              await setUpPartnership();
          final good = await investor.next(
            partnership: partnershipId,
            type: type,
            body: {'amount': 1000},
          );
          expect(await _receive(validator, good), ReceiveOutcome.accepted);

          await _expectAllRejected(validator, {
            'refersTo must be null': good.copyWith(refersTo: testId('x')),
            'amount is zero': good.copyWith(body: {'amount': 0}),
            'amount is negative': good.copyWith(body: {'amount': -5}),
            'amount is the wrong type': good.copyWith(body: {'amount': '1000'}),
            'amount is missing': good.copyWith(body: const {}),
          });
        },
      );
    }
  });

  group('spec section 5 — budget_proposal', () {
    test(
      'refersTo must be null, grantee a canonical key, amount a positive integer',
      () async {
        final (validator, investor, manager, partnershipId) =
            await setUpPartnership();
        final good = await investor.next(
          partnership: partnershipId,
          type: 'budget_proposal',
          body: {'grantee': manager.key, 'amount': 5000},
        );
        expect(await _receive(validator, good), ReceiveOutcome.accepted);

        await _expectAllRejected(validator, {
          'refersTo must be null': good.copyWith(refersTo: testId('x')),
          'amount is zero': good.copyWith(body: {...good.body, 'amount': 0}),
          'amount is the wrong type': good.copyWith(
            body: {...good.body, 'amount': '5000'},
          ),
          'grantee is missing': good.copyWith(body: {'amount': 5000}),
          'grantee is the wrong type': good.copyWith(
            body: {...good.body, 'grantee': 12345},
          ),
          'grantee is not a canonical public key': good.copyWith(
            body: {...good.body, 'grantee': 'not-a-key'},
          ),
        });
      },
    );
  });

  group('spec section 5 — expense', () {
    test(
      'refersTo is required and must be a UUID, amount positive, receiptHash hex or null',
      () async {
        final (validator, _, manager, partnershipId) = await setUpPartnership();
        final good = await manager.next(
          partnership: partnershipId,
          type: 'expense',
          body: {'amount': 3000, 'receiptHash': null},
          refersTo: testId('dummy-budget'),
        );
        expect(await _receive(validator, good), ReceiveOutcome.accepted);

        await _expectAllRejected(validator, {
          'refersTo is required, not null': _withNullRefersTo(good),
          'refersTo must be a UUID': good.copyWith(refersTo: 'not-a-uuid'),
          'amount is zero': good.copyWith(body: {...good.body, 'amount': 0}),
          'amount is the wrong type': good.copyWith(
            body: {...good.body, 'amount': '3000'},
          ),
          'receiptHash is too short to be a hash': good.copyWith(
            body: {...good.body, 'receiptHash': 'ab12'},
          ),
          'receiptHash has an uppercase letter': good.copyWith(
            body: {...good.body, 'receiptHash': 'A' * 64},
          ),
        });

        // receiptHash: null is allowed (the good case above already shows
        // this), and so is a real 64-character hex hash. This needs its own
        // signature, since it is a genuinely different, valid record, not a
        // broken variant of `good` — `copyWith` would leave `good`'s
        // signature on body it no longer matches, and get rejected for a
        // different reason (step 2) than the one this case checks (step 1).
        final withHash = await manager.next(
          partnership: partnershipId,
          type: 'expense',
          body: {'amount': 3000, 'receiptHash': '0' * 64},
          refersTo: testId('dummy-budget'),
        );
        expect(await _receive(validator, withHash), ReceiveOutcome.accepted);
      },
    );
  });

  group('spec section 5 — withdraw_request', () {
    test(
      'refersTo must be null, amount a positive integer, kind capital or profit',
      () async {
        final (validator, investor, _, partnershipId) =
            await setUpPartnership();
        final good = await investor.next(
          partnership: partnershipId,
          type: 'withdraw_request',
          body: {'amount': 500, 'kind': 'profit'},
        );
        expect(await _receive(validator, good), ReceiveOutcome.accepted);

        await _expectAllRejected(validator, {
          'refersTo must be null': good.copyWith(refersTo: testId('x')),
          'amount is zero': good.copyWith(body: {...good.body, 'amount': 0}),
          'amount is the wrong type': good.copyWith(
            body: {...good.body, 'amount': '500'},
          ),
          'kind is missing': good.copyWith(body: {'amount': 500}),
          'kind is neither capital nor profit': good.copyWith(
            body: {...good.body, 'kind': 'bonus'},
          ),
        });
      },
    );
  });

  group('spec section 5 — ratio_proposal', () {
    test(
      'refersTo must be null, ratio shares 1-99 and sum to 100, effectiveFrom a date',
      () async {
        final (validator, investor, _, partnershipId) =
            await setUpPartnership();
        final good = await investor.next(
          partnership: partnershipId,
          type: 'ratio_proposal',
          body: {
            'ratio': {'investor': 50, 'manager': 50},
            'effectiveFrom': '2026-11-01',
          },
        );
        expect(await _receive(validator, good), ReceiveOutcome.accepted);

        await _expectAllRejected(validator, {
          'refersTo must be null': good.copyWith(refersTo: testId('x')),
          'a ratio share of 100 is out of range': good.copyWith(
            body: {
              ...good.body,
              'ratio': {'investor': 100, 'manager': 0},
            },
          ),
          'a ratio that does not add up to 100': good.copyWith(
            body: {
              ...good.body,
              'ratio': {'investor': 90, 'manager': 20},
            },
          ),
          'effectiveFrom is missing': good.copyWith(
            body: {'ratio': good.body['ratio']},
          ),
          'effectiveFrom is not in YYYY-MM-DD shape': good.copyWith(
            body: {...good.body, 'effectiveFrom': '01-11-2026'},
          ),
        });
      },
    );
  });

  group('spec section 5 — reversal, approve, reject', () {
    for (final type in ['reversal', 'approve', 'reject']) {
      test(
        '$type: refersTo is required and must be a UUID, body must be empty',
        () async {
          final (validator, investor, _, partnershipId) =
              await setUpPartnership();
          final good = await investor.next(
            partnership: partnershipId,
            type: type,
            refersTo: testId('some-target'),
          );
          expect(await _receive(validator, good), ReceiveOutcome.accepted);

          await _expectAllRejected(validator, {
            'refersTo is required, not null': _withNullRefersTo(good),
            'refersTo must be a UUID': good.copyWith(refersTo: 'some-record'),
            'body must be empty': good.copyWith(body: {'note': 'x'}),
          });
        },
      );
    }
  });

  group('spec section 5 — settlement', () {
    test('refersTo must be null, cut must be a map', () async {
      final (validator, _, manager, partnershipId) = await setUpPartnership();
      final good = await manager.next(
        partnership: partnershipId,
        type: settlementType,
        body: {
          'cut': {'a': 1, 'b': 2},
        },
      );
      expect(await _receive(validator, good), ReceiveOutcome.accepted);

      await _expectAllRejected(validator, {
        'refersTo must be null': good.copyWith(refersTo: testId('x')),
        'cut is missing': good.copyWith(body: const {}),
        'cut is not a map': good.copyWith(body: {'cut': 'not-a-map'}),
      });
    });
  });
}
