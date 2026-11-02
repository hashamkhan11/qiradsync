import 'package:qirad_core/qirad_core.dart';
import 'package:test/test.dart';

void main() {
  group('isValidShare (spec section 5)', () {
    test('1 and 99 are the inclusive bounds', () {
      expect(isValidShare(1), isTrue);
      expect(isValidShare(99), isTrue);
    });

    test('a share in between is valid', () {
      expect(isValidShare(50), isTrue);
    });

    test('0 is not valid: nobody shares in no profit', () {
      expect(isValidShare(0), isFalse);
    });

    test('100 is not valid: nobody shares in no profit', () {
      expect(isValidShare(100), isFalse);
    });

    test('a negative share is not valid', () {
      expect(isValidShare(-1), isFalse);
    });

    test('a non-int value is not valid', () {
      expect(isValidShare(50.0), isFalse);
      expect(isValidShare(null), isFalse);
      expect(isValidShare('50'), isFalse);
    });
  });
}
