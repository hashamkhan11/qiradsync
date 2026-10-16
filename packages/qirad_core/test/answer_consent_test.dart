import 'package:qirad_core/qirad_core.dart';
import 'package:test/test.dart';

import 'support/partnership_fixture.dart';
import 'support/test_ids.dart';

/// An unsaved approve by [author] of [targetId], built the same way a phone
/// builds its own answer. It is only an input to [answerConsent].
Record _candidateApprove(
  Validator validator,
  String author,
  String partnership,
  String targetId,
) => buildRecord(
  ledger: validator.usableRecords,
  author: author,
  partnership: partnership,
  id: testId('candidate-approve-$targetId'),
  type: 'approve',
  body: const {},
  time: '2026-10-11T10:00:00Z',
  refersTo: targetId,
);

void main() {
  group('answerConsent (spec 6.7)', () {
    test(
      'approving a later settlement before an earlier one is answered is '
      'refused (answerEarlierFirst)',
      () async {
        final (validator, investor, manager, partnership) =
            await setUpPartnership();
        final s1 = await manager.next(
          partnership: partnership,
          type: 'settlement',
          body: {
            'cut': {investor.key: 1, manager.key: 1},
          },
        );
        await validator.receiveText(canonicalJson(s1.toJson()));
        final s2 = await manager.next(
          partnership: partnership,
          type: 'settlement',
          body: {
            'cut': {investor.key: 1, manager.key: 1},
          },
        );
        await validator.receiveText(canonicalJson(s2.toJson()));

        final candidate = _candidateApprove(
          validator,
          investor.key,
          partnership,
          s2.id,
        );

        final result = answerConsent(
          targetId: s2.id,
          approve: true,
          candidate: candidate,
          validator: validator,
        );

        expect(result?.reason, AnswerConsentRefusal.answerEarlierFirst);
      },
    );

    test(
      'a reject does not need a summary, since it never takes effect',
      () async {
        final (validator, investor, manager, partnership) =
            await setUpPartnership();
        // The only (so not out of order) settlement proposal: rejecting it
        // needs no shown summary, only an approve would.
        final s1 = await manager.next(
          partnership: partnership,
          type: 'settlement',
          body: {
            'cut': {investor.key: 1, manager.key: 1},
          },
        );
        await validator.receiveText(canonicalJson(s1.toJson()));

        final candidate = buildRecord(
          ledger: validator.usableRecords,
          author: investor.key,
          partnership: partnership,
          id: testId('candidate-reject-s1'),
          type: 'reject',
          body: const {},
          time: '2026-10-11T10:00:00Z',
          refersTo: s1.id,
        );

        final result = answerConsent(
          targetId: s1.id,
          approve: false,
          candidate: candidate,
          validator: validator,
        );

        expect(result, isNull);
      },
    );

    test(
      'approving a budget proposal with no shown summary is refused '
      '(consentNotShown)',
      () async {
        final (validator, investor, manager, partnership) =
            await setUpPartnership();
        final keys = {investor.key, manager.key};
        final proposal = await investor.next(
          partnership: partnership,
          type: 'budget_proposal',
          body: {'grantee': manager.key, 'amount': 5000},
        );
        await validator.receiveText(canonicalJson(proposal.toJson()));

        final candidate = _candidateApprove(
          validator,
          manager.key,
          partnership,
          proposal.id,
        );
        final now = budgetConsent(
          validator.usableRecords,
          partnershipKeys: keys,
          proposal: proposal,
        );

        final result = answerConsent(
          targetId: proposal.id,
          approve: true,
          candidate: candidate,
          validator: validator,
        );

        expect(result?.reason, AnswerConsentRefusal.consentNotShown);
        expect(result?.latestBudget, now);
      },
    );

    test(
      'approving a budget proposal whose numbers moved since they were '
      'shown is refused (summaryChanged)',
      () async {
        final (validator, investor, manager, partnership) =
            await setUpPartnership();
        final keys = {investor.key, manager.key};
        final proposal = await investor.next(
          partnership: partnership,
          type: 'budget_proposal',
          body: {'grantee': manager.key, 'amount': 5000},
        );
        await validator.receiveText(canonicalJson(proposal.toJson()));

        final candidate = _candidateApprove(
          validator,
          manager.key,
          partnership,
          proposal.id,
        );
        final now = budgetConsent(
          validator.usableRecords,
          partnershipKeys: keys,
          proposal: proposal,
        )!;
        final stale = BudgetConsent(
          grantee: now.grantee,
          amount: now.amount,
          cashBalance: now.cashBalance + 1,
          openBudgets: now.openBudgets,
        );

        final result = answerConsent(
          targetId: proposal.id,
          approve: true,
          candidate: candidate,
          validator: validator,
          shownBudget: stale,
        );

        expect(result?.reason, AnswerConsentRefusal.summaryChanged);
        expect(result?.latestBudget, now);
      },
    );

    test(
      'approving a capital withdrawal for more than current capital is '
      'refused (overCapital), and carries the amount actually left',
      () async {
        final (validator, investor, manager, partnership) =
            await setUpPartnership();
        final invest = await investor.next(
          partnership: partnership,
          type: 'invest',
          body: {'amount': 1000},
        );
        await validator.receiveText(canonicalJson(invest.toJson()));
        // Written directly (bypassing proposalRefusal) to model a request
        // that reached this phone despite the propose-side guard, the way a
        // forged or pre-fix record would (decision 2026-10-16).
        final request = await investor.next(
          partnership: partnership,
          type: 'withdraw_request',
          body: {'amount': 1500, 'kind': 'capital'},
        );
        await validator.receiveText(canonicalJson(request.toJson()));

        final candidate = _candidateApprove(
          validator,
          manager.key,
          partnership,
          request.id,
        );

        final result = answerConsent(
          targetId: request.id,
          approve: true,
          candidate: candidate,
          validator: validator,
        );

        expect(result?.reason, AnswerConsentRefusal.overCapital);
        expect(result?.capitalLeft, 1000);
      },
    );

    test(
      'approving a profit withdrawal is never refused by the capital check, '
      'even past what capital would allow',
      () async {
        final (validator, investor, manager, partnership) =
            await setUpPartnership();
        final sale = await manager.next(
          partnership: partnership,
          type: 'sale',
          body: {'amount': 5000},
        );
        await validator.receiveText(canonicalJson(sale.toJson()));
        final request = await manager.next(
          partnership: partnership,
          type: 'withdraw_request',
          body: {'amount': 5000, 'kind': 'profit'},
        );
        await validator.receiveText(canonicalJson(request.toJson()));

        final candidate = _candidateApprove(
          validator,
          investor.key,
          partnership,
          request.id,
        );
        final shown = withdrawalConsent(
          validator.usableRecords,
          partnershipKeys: {investor.key, manager.key},
          request: request,
          answer: candidate,
        );

        final result = answerConsent(
          targetId: request.id,
          approve: true,
          candidate: candidate,
          validator: validator,
          shownWithdrawal: shown,
        );

        expect(result, isNull);
      },
    );

    test(
      'approving a budget proposal with the summary the user was just shown '
      'is allowed',
      () async {
        final (validator, investor, manager, partnership) =
            await setUpPartnership();
        final keys = {investor.key, manager.key};
        final proposal = await investor.next(
          partnership: partnership,
          type: 'budget_proposal',
          body: {'grantee': manager.key, 'amount': 5000},
        );
        await validator.receiveText(canonicalJson(proposal.toJson()));

        final candidate = _candidateApprove(
          validator,
          manager.key,
          partnership,
          proposal.id,
        );
        final shown = budgetConsent(
          validator.usableRecords,
          partnershipKeys: keys,
          proposal: proposal,
        );

        final result = answerConsent(
          targetId: proposal.id,
          approve: true,
          candidate: candidate,
          validator: validator,
          shownBudget: shown,
        );

        expect(result, isNull);
      },
    );
  });
}
