import 'package:qirad_core/qirad_core.dart';
import 'package:test/test.dart';

import 'support/partnership_fixture.dart';
import 'support/test_ids.dart';

/// Builds a signed create with the body from [bodyFor] and runs it through a
/// fresh validator. The keys are real, so only the body can make it invalid.
Future<ReceiveOutcome> _receiveCreate(
  Map<String, dynamic> Function(String investor, String manager) bodyFor,
) async {
  final investor = ChainAuthor(await generateEd25519KeyPair());
  final manager = ChainAuthor(await generateEd25519KeyPair());
  final id = testId('partnership-body');
  final create = await investor.next(
    partnership: id,
    type: 'partnership_create',
    id: id,
    body: bodyFor(investor.key, manager.key),
  );
  return Validator.unpinnedForTesting().receiveText(
    canonicalJson(create.toJson()),
  );
}

Map<String, dynamic> _body(
  String investor,
  String manager, {
  Object? ratio = const {'investor': 60, 'manager': 40},
}) => {
  'investor': investor,
  'manager': manager,
  'ratio': ratio,
  'currency': 'PKR',
};

void main() {
  group('partnership_create body (spec 5, 6.7)', () {
    test('a create with two keys and a ratio of 60/40 is accepted', () async {
      final outcome = await _receiveCreate(_body);
      expect(outcome, ReceiveOutcome.accepted);
    });

    test('a ratio whose shares do not add up to 100 is refused', () async {
      final outcome = await _receiveCreate(
        (i, m) => _body(i, m, ratio: {'investor': 60, 'manager': 50}),
      );
      expect(outcome, ReceiveOutcome.rejectedSchema);
    });

    test('a share of 0 is refused, even if the sum is 100', () async {
      final outcome = await _receiveCreate(
        (i, m) => _body(i, m, ratio: {'investor': 100, 'manager': 0}),
      );
      expect(outcome, ReceiveOutcome.rejectedSchema);
    });

    test('a create with no ratio is refused', () async {
      final outcome = await _receiveCreate(
        (i, m) => {'investor': i, 'manager': m, 'currency': 'PKR'},
      );
      expect(outcome, ReceiveOutcome.rejectedSchema);
    });

    test('a create with the same key for both partners is refused', () async {
      final outcome = await _receiveCreate((i, _) => _body(i, i));
      expect(outcome, ReceiveOutcome.rejectedSchema);
    });

    test('a create with no manager key is refused', () async {
      final outcome = await _receiveCreate(
        (i, _) => {
          'investor': i,
          'ratio': {'investor': 60, 'manager': 40},
          'currency': 'PKR',
        },
      );
      expect(outcome, ReceiveOutcome.rejectedSchema);
    });
  });
}
