import 'dart:convert';

import 'package:qirad_core/qirad_core.dart';
import 'package:test/test.dart';

void main() {
  group('canonicalJson', () {
    test('sorts top-level keys by Unicode code point', () {
      final result = canonicalJson({'b': 1, 'a': 2, 'c': 3});

      expect(result, '{"a":2,"b":1,"c":3}');
    });

    test('sorts keys inside a nested body object too', () {
      final result = canonicalJson({
        'type': 'expense',
        'body': {'note': 'x', 'amount': 500, 'budgetId': 'b1'},
      });

      expect(result, '{"body":{"amount":500,"budgetId":"b1","note":"x"},"type":"expense"}');
    });

    test('writes no whitespace anywhere', () {
      final result = canonicalJson({
        'a': {'b': [1, 2, 3]},
      });

      expect(result, isNot(contains(' ')));
      expect(result, isNot(contains('\n')));
      expect(result, '{"a":{"b":[1,2,3]}}');
    });

    test('writes null as the literal null', () {
      expect(canonicalJson({'refersTo': null}), '{"refersTo":null}');
    });

    test('rejects doubles, since money and all numbers must be integers', () {
      expect(() => canonicalJson({'amount': 5.0}), throwsArgumentError);
    });

    test('round-trips through jsonDecode back to the same values', () {
      final original = {
        'seq': 3,
        'note': 'quoted "text" and a \\ backslash',
        'body': {'z': 1, 'a': 2},
        'refersTo': null,
      };

      final decoded = jsonDecode(canonicalJson(original)) as Map<String, dynamic>;

      expect(decoded['seq'], 3);
      expect(decoded['note'], 'quoted "text" and a \\ backslash');
      expect(decoded['refersTo'], isNull);
      expect(decoded['body'], {'z': 1, 'a': 2});
    });
  });
}
