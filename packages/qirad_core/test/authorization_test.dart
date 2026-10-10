import 'package:qirad_core/qirad_core.dart';
import 'package:test/test.dart';

void main() {
  const investor = 'INVESTOR_KEY';
  const manager = 'MANAGER_KEY';
  const parties = Parties(investor: investor, manager: manager);

  group('canAuthor (spec section 5, "Allowed author")', () {
    test('partnership_create and invest are investor only', () {
      for (final type in ['partnership_create', 'invest']) {
        expect(canAuthor(type, investor, parties), isTrue);
        expect(canAuthor(type, manager, parties), isFalse);
      }
    });

    test('sale, expense and settlement are manager only', () {
      for (final type in ['sale', 'expense', 'settlement']) {
        expect(canAuthor(type, manager, parties), isTrue);
        expect(canAuthor(type, investor, parties), isFalse);
      }
    });

    test(
      'a capital withdraw_request is investor only (decision 2026-10-10)',
      () {
        expect(
          canAuthor('withdraw_request', investor, parties, kind: 'capital'),
          isTrue,
        );
        expect(
          canAuthor('withdraw_request', manager, parties, kind: 'capital'),
          isFalse,
        );
      },
    );

    test('a profit withdraw_request is open to either partner', () {
      expect(
        canAuthor('withdraw_request', investor, parties, kind: 'profit'),
        isTrue,
      );
      expect(
        canAuthor('withdraw_request', manager, parties, kind: 'profit'),
        isTrue,
      );
    });

    test(
      'budget_proposal, ratio_proposal, reversal, approve and reject are '
      'open to either partner',
      () {
        for (final type in [
          'budget_proposal',
          'ratio_proposal',
          'reversal',
          'approve',
          'reject',
        ]) {
          expect(canAuthor(type, investor, parties), isTrue);
          expect(canAuthor(type, manager, parties), isTrue);
        }
      },
    );
  });

  group('allowedCreationActions', () {
    test(
      'is exactly what canAuthor allows, for both roles (so the "New" menu '
      'never offers a button a propose* call would refuse)',
      () {
        for (final me in [investor, manager]) {
          final allowed = allowedCreationActions(me, parties);
          for (final action in CreationAction.values) {
            final (type, kind) = recordKindFor(action);
            expect(
              allowed.contains(action),
              canAuthor(type, me, parties, kind: kind),
              reason: '$action for $me',
            );
          }
        }
      },
    );

    test('the investor sees invest and the capital withdrawal, not sale', () {
      final allowed = allowedCreationActions(investor, parties);
      expect(allowed, contains(CreationAction.invest));
      expect(allowed, contains(CreationAction.withdrawCapital));
      expect(allowed, isNot(contains(CreationAction.sale)));
    });

    test(
      'the manager sees sale and settlement, not invest or the capital '
      'withdrawal',
      () {
        final allowed = allowedCreationActions(manager, parties);
        expect(allowed, contains(CreationAction.sale));
        expect(allowed, contains(CreationAction.settlement));
        expect(allowed, isNot(contains(CreationAction.invest)));
        expect(allowed, isNot(contains(CreationAction.withdrawCapital)));
      },
    );

    test('both partners see the actions open to either role', () {
      for (final me in [investor, manager]) {
        final allowed = allowedCreationActions(me, parties);
        expect(allowed, contains(CreationAction.budget));
        expect(allowed, contains(CreationAction.ratio));
        expect(allowed, contains(CreationAction.reversal));
        expect(allowed, contains(CreationAction.withdrawProfit));
      }
    });
  });
}
