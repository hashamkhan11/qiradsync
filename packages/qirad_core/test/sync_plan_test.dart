import 'package:qirad_core/qirad_core.dart';
import 'package:test/test.dart';

void main() {
  group('firstMissingSeqs', () {
    test('nothing is missing when the relay matches the local vector', () {
      expect(
        firstMissingSeqs(
          local: {'investor': 3, 'manager': 2},
          relay: {'investor': 3, 'manager': 2},
        ),
        isEmpty,
      );
    });

    test('an author the relay has never seen starts at seq 1', () {
      expect(firstMissingSeqs(local: {'manager': 4}, relay: {'investor': 2}), {
        'manager': 1,
      });
    });

    test('a relay behind on one author gets the next seq after its vector', () {
      expect(
        firstMissingSeqs(
          local: {'investor': 4, 'manager': 3},
          relay: {'investor': 2, 'manager': 3},
        ),
        {'investor': 3},
      );
    });

    test('a relay ahead of us is never listed: it needs no upload', () {
      expect(
        firstMissingSeqs(local: {'investor': 2}, relay: {'investor': 9}),
        isEmpty,
      );
    });

    test('an empty local vector needs nothing', () {
      expect(firstMissingSeqs(local: {}, relay: {'investor': 5}), isEmpty);
    });
  });
}
