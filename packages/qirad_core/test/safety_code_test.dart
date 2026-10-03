import 'package:qirad_core/qirad_core.dart';
import 'package:test/test.dart';

void main() {
  // Keys of 32 bytes of 0x01 and 0x02. The expected code was computed with a
  // separate SHA-256 implementation (Python hashlib), so this checks the rule,
  // not just that the function agrees with itself.
  final investor = encodeBase64UrlNoPadding(List.filled(32, 1));
  final manager = encodeBase64UrlNoPadding(List.filled(32, 2));

  group('safetyCode', () {
    test('matches the known answer for the spec 2.1 rule', () {
      expect(
        safetyCode(investorKey: investor, managerKey: manager),
        '8055 0942 1295 6436 3874 1653',
      );
    });

    test('same keys give the same code, every time', () {
      final first = safetyCode(investorKey: investor, managerKey: manager);
      final second = safetyCode(investorKey: investor, managerKey: manager);

      expect(second, first);
    });

    test('is 24 digits in 6 groups of 4', () {
      final code = safetyCode(investorKey: investor, managerKey: manager);

      expect(RegExp(r'^\d{4}( \d{4}){5}$').hasMatch(code), isTrue);
    });

    test('swapping the investor and manager keys gives a different code', () {
      final normal = safetyCode(investorKey: investor, managerKey: manager);
      final swapped = safetyCode(investorKey: manager, managerKey: investor);

      expect(swapped, isNot(normal));
    });

    test('changing either key gives a different code', () async {
      final normal = safetyCode(investorKey: investor, managerKey: manager);
      final otherInvestor = (await generateEd25519KeyPair()).publicKeyBase64Url;
      final otherManager = (await generateEd25519KeyPair()).publicKeyBase64Url;

      expect(
        safetyCode(investorKey: otherInvestor, managerKey: manager),
        isNot(normal),
      );
      expect(
        safetyCode(investorKey: investor, managerKey: otherManager),
        isNot(normal),
      );
    });

    test('refuses a key that is too short', () {
      expect(
        () => safetyCode(
          investorKey: investor.substring(0, 42),
          managerKey: manager,
        ),
        throwsArgumentError,
      );
    });

    test('refuses a second spelling of a key', () {
      // Flipping the lowest bit of the last character changes only the 2 unused
      // bits, so it is a different text for the same key. It must be refused.
      const alphabet =
          'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
      final last = alphabet.indexOf(manager[42]);
      final otherSpelling = manager.substring(0, 42) + alphabet[last ^ 1];

      expect(
        () => safetyCode(investorKey: investor, managerKey: otherSpelling),
        throwsArgumentError,
      );
    });
  });
}
