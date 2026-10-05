import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/dashboard/format.dart';
import 'package:qirad_core/qirad_core.dart';

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

  group('formatRatio', () {
    test('says when the ratio was agreed to start', () {
      final active = ActiveRatio(
        ratio: const Ratio(investor: 50, manager: 50),
        agreedStart: '2026-11-01',
      );
      expect(formatRatio(active), '50/50 (agreed to start 2026-11-01)');
    });

    test('says from the start when no change was made', () {
      final active = ActiveRatio(
        ratio: const Ratio(investor: 60, manager: 40),
        agreedStart: null,
      );
      expect(formatRatio(active), '60/40 (from the start)');
    });
  });
}
