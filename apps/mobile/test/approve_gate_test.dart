import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/inbox/approve_gate.dart';

void main() {
  group('canShowApprove (spec 6.7, informed consent)', () {
    test('no summary yet: false, whatever else is true', () {
      expect(
        canShowApprove(summary: null, blockedReason: null, needsSync: false),
        isFalse,
      );
    });

    test('the inbox gives a blocked reason: false, even with a summary', () {
      expect(
        canShowApprove(
          summary: 'a summary', // the function only checks null-ness
          blockedReason: 'This settlement covers nothing new. Reject it.',
          needsSync: false,
        ),
        isFalse,
      );
    });

    test('this phone needs to sync first: false, even with a summary', () {
      expect(
        canShowApprove(
          summary: 'a summary',
          blockedReason: null,
          needsSync: true,
        ),
        isFalse,
      );
    });

    test('a summary, no blocked reason, no sync needed: true', () {
      expect(
        canShowApprove(
          summary: 'a summary',
          blockedReason: null,
          needsSync: false,
        ),
        isTrue,
      );
    });
  });
}
