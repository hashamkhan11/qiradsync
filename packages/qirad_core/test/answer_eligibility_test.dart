import 'package:qirad_core/qirad_core.dart';
import 'package:test/test.dart';

import 'support/partnership_fixture.dart';

void main() {
  group('answerEligibility (spec sections 5, 6.7, 7.4)', () {
    test('a pending proposal with no response yet is answerable', () async {
      final (validator, investor, manager, partnership) =
          await setUpPartnership();
      final proposal = await investor.next(
        partnership: partnership,
        type: 'budget_proposal',
        body: {'grantee': manager.key, 'amount': 5000},
      );
      await validator.receiveText(canonicalJson(proposal.toJson()));

      expect(
        answerEligibility(
          targetId: proposal.id,
          me: manager.key,
          validator: validator,
        ),
        isNull,
      );
    });

    test('an unknown id is notAnswerable', () async {
      final (validator, _, manager, _) = await setUpPartnership();

      expect(
        answerEligibility(
          targetId: 'no-such-id',
          me: manager.key,
          validator: validator,
        ),
        AnswerEligibilityRefusal.notAnswerable,
      );
    });

    test('the proposer answering their own proposal is notAnswerable', () async {
      final (validator, investor, manager, partnership) =
          await setUpPartnership();
      final proposal = await investor.next(
        partnership: partnership,
        type: 'budget_proposal',
        body: {'grantee': manager.key, 'amount': 5000},
      );
      await validator.receiveText(canonicalJson(proposal.toJson()));

      expect(
        answerEligibility(
          targetId: proposal.id,
          me: investor.key,
          validator: validator,
        ),
        AnswerEligibilityRefusal.notAnswerable,
      );
    });

    test('answering again after a valid answer is alreadyAnswered', () async {
      final (validator, investor, manager, partnership) =
          await setUpPartnership();
      final proposal = await investor.next(
        partnership: partnership,
        type: 'budget_proposal',
        body: {'grantee': manager.key, 'amount': 5000},
      );
      final approve = await manager.next(
        partnership: partnership,
        type: 'approve',
        refersTo: proposal.id,
      );
      await validator.receiveText(canonicalJson(proposal.toJson()));
      await validator.receiveText(canonicalJson(approve.toJson()));

      expect(
        answerEligibility(
          targetId: proposal.id,
          me: manager.key,
          validator: validator,
        ),
        AnswerEligibilityRefusal.alreadyAnswered,
      );
    });

    test(
      'a key that did not supply the deciding answer sees alreadyDecided, '
      'once the proposal is no longer pending',
      () async {
        final (validator, investor, manager, partnership) =
            await setUpPartnership();
        final proposal = await investor.next(
          partnership: partnership,
          type: 'budget_proposal',
          body: {'grantee': manager.key, 'amount': 5000},
        );
        final approve = await manager.next(
          partnership: partnership,
          type: 'approve',
          refersTo: proposal.id,
        );
        await validator.receiveText(canonicalJson(proposal.toJson()));
        await validator.receiveText(canonicalJson(approve.toJson()));

        // Not the proposer (so not notAnswerable) and not manager (whose
        // approve already decided it, so not alreadyAnswered either).
        expect(
          answerEligibility(
            targetId: proposal.id,
            me: 'SOME_OTHER_KEY',
            validator: validator,
          ),
          AnswerEligibilityRefusal.alreadyDecided,
        );
      },
    );

    test(
      'answering anything but the create itself before the partnership is '
      'active is partnershipNotActive',
      () async {
        final (validator, investor, manager, partnership) =
            await setUpUnapprovedPartnership();
        final proposal = await investor.next(
          partnership: partnership,
          type: 'budget_proposal',
          body: {'grantee': manager.key, 'amount': 5000},
        );
        await validator.receiveText(canonicalJson(proposal.toJson()));

        expect(
          answerEligibility(
            targetId: proposal.id,
            me: manager.key,
            validator: validator,
          ),
          AnswerEligibilityRefusal.partnershipNotActive,
        );
      },
    );
  });
}
