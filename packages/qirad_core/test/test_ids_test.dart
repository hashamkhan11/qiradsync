import 'package:test/test.dart';

import 'support/test_ids.dart';

void main() {
  final uuidV4 = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  );

  group('testId', () {
    test('gives a lowercase UUID v4 for any name', () {
      for (final name in ['invest-2', 'partnership-1', 'r\$1-2', 'x']) {
        expect(testId(name), matches(uuidV4), reason: name);
      }
    });

    test('the same name always gives the same id', () {
      expect(testId('invest-2'), testId('invest-2'));
    });

    test('different names give different ids', () {
      expect(testId('invest-2'), isNot(testId('invest-3')));
    });

    test('matches the PHP helper (relay/tests/Support/TestIds.php)', () {
      // These values were printed by the PHP helper. If either side changes,
      // the shared fixtures would no longer agree.
      expect(testId('invest-2'), 'ab846771-b23d-4f06-a68a-5deaa979fc5a');
      expect(testId('partnership-1'), 'fc3651ef-df78-46bf-9fc8-d3ef8c2c9f20');
    });
  });
}
