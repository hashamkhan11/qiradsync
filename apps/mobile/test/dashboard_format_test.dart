import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/dashboard/format.dart';

void main() {
  group('formatPaisa', () {
    test('shows whole rupees with two decimals', () {
      expect(formatPaisa(120000), 'Rs 1,200.00');
      expect(formatPaisa(5), 'Rs 0.05');
      expect(formatPaisa(0), 'Rs 0.00');
    });

    test('groups thousands with commas', () {
      expect(formatPaisa(100000000), 'Rs 1,000,000.00');
      expect(formatPaisa(99999), 'Rs 999.99');
    });

    test('shows a loss with a minus sign in front', () {
      expect(formatPaisa(-20000000), '-Rs 200,000.00');
    });
  });

  group('localDateLabel', () {
    test('gives YYYY-MM-DD with leading zeros', () {
      expect(localDateLabel(DateTime(2026, 1, 5, 23, 59)), '2026-01-05');
      expect(localDateLabel(DateTime(2026, 10, 12)), '2026-10-12');
    });
  });
}
