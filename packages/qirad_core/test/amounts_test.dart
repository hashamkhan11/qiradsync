import 'package:qirad_core/qirad_core.dart';
import 'package:test/test.dart';

Record _recordWithAmount(Object? amount) => Record(
  v: 1,
  id: 'r1',
  partnership: 'p1',
  author: 'a1',
  seq: 1,
  prevHash: 'GENESIS',
  type: 'invest',
  body: {'amount': amount},
  refersTo: null,
  note: '',
  time: '2026-01-01T00:00:00Z',
  sig: 'sig',
);

void main() {
  group('isPositiveAmount (spec section 5, hard rule 1)', () {
    test('a positive integer is positive', () {
      expect(isPositiveAmount(1), isTrue);
      expect(isPositiveAmount(100000), isTrue);
    });

    test('zero is not positive', () {
      expect(isPositiveAmount(0), isFalse);
    });

    test('a negative integer is not positive', () {
      expect(isPositiveAmount(-1), isFalse);
    });

    test('a double is rejected, even a whole one', () {
      // Money is always an integer in paisa (hard rule 1); a double should
      // never reach this check, but it must not be treated as valid either.
      expect(isPositiveAmount(1.0), isFalse);
    });

    test('null and other non-int values are rejected', () {
      expect(isPositiveAmount(null), isFalse);
      expect(isPositiveAmount('100'), isFalse);
    });
  });

  group('positiveAmount (Record)', () {
    test('reads a positive amount from the body', () {
      expect(positiveAmount(_recordWithAmount(500)), 500);
    });

    test('returns null for a zero amount', () {
      expect(positiveAmount(_recordWithAmount(0)), isNull);
    });

    test('returns null for a negative amount', () {
      expect(positiveAmount(_recordWithAmount(-500)), isNull);
    });

    test('returns null when the body has no amount at all', () {
      expect(positiveAmount(_recordWithAmount(null)), isNull);
    });
  });
}
