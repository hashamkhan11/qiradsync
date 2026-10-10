import 'package:qirad_core/qirad_core.dart';
import 'package:test/test.dart';

void main() {
  group('parseRupeesToPaisa (hard rule 1: money is always an integer)', () {
    test('whole rupees, with and without a thousands separator', () {
      expect(parseRupeesToPaisa('5'), 500);
      expect(parseRupeesToPaisa('1,234'), 123400);
    });

    test('two decimal places', () {
      expect(parseRupeesToPaisa('0.10'), 10);
      expect(parseRupeesToPaisa('1,234.5'), 123450);
      expect(parseRupeesToPaisa('1.05'), 105);
    });

    test('surrounding whitespace is trimmed, not a reason to refuse', () {
      expect(parseRupeesToPaisa('  100  '), 10000);
    });

    test('zero is a valid amount to parse (callers decide if 0 makes sense)', () {
      expect(parseRupeesToPaisa('0'), 0);
    });

    test('more than two decimal places is rejected', () {
      expect(parseRupeesToPaisa('1.234'), isNull);
    });

    test('a negative amount is rejected', () {
      expect(parseRupeesToPaisa('-5'), isNull);
    });

    test('an empty field is rejected', () {
      expect(parseRupeesToPaisa(''), isNull);
    });

    test('text that is not a number is rejected', () {
      expect(parseRupeesToPaisa('abc'), isNull);
      expect(parseRupeesToPaisa('12,34.5.6'), isNull);
      expect(parseRupeesToPaisa('.'), isNull);
    });
  });
}
