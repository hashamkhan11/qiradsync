import 'package:qirad_core/qirad_core.dart';
import 'package:test/test.dart';

import 'support/partnership_fixture.dart';
import 'support/test_ids.dart';

/// An unsaved approve by [author] of [targetId], built on [usable] the same way
/// a phone builds its own record. It is only an input to the summary.
Record _candidateApprove(
  Iterable<Record> usable,
  String author,
  String partnership,
  String targetId,
) => buildRecord(
  ledger: usable,
  author: author,
  partnership: partnership,
  id: testId('candidate-approve-$targetId'),
  type: 'approve',
  body: const {},
  time: '2026-10-06T10:00:00Z',
  refersTo: targetId,
);

void main() {
  group('consent summary (spec 6.7, step 4)', () {
    test(
      'a settlement summary equals the period core reports once it is effective',
      () async {
        final (validator, investor, manager, partnership) =
            await setUpPartnership();
        final keys = {investor.key, manager.key};

        // Records that make a period with a result: an invest and a sale.
        expect(
          await validator.receiveText(
            canonicalJson(
              (await investor.next(
                partnership: partnership,
                type: 'invest',
                body: {'amount': 100000},
              )).toJson(),
            ),
          ),
          ReceiveOutcome.accepted,
        );
        expect(
          await validator.receiveText(
            canonicalJson(
              (await manager.next(
                partnership: partnership,
                type: 'sale',
                body: {'amount': 50000},
              )).toJson(),
            ),
          ),
          ReceiveOutcome.accepted,
        );

        // The manager proposes the settlement. The cut covers the investor's
        // seqs 1 and 2 and the manager's seq 1.
        final proposal = await manager.next(
          partnership: partnership,
          type: 'settlement',
          body: {
            'cut': {investor.key: 2, manager.key: 1},
          },
        );
        expect(
          await validator.receiveText(canonicalJson(proposal.toJson())),
          ReceiveOutcome.accepted,
        );

        // Before the answer: the summary uses an unsaved approve as input.
        final candidate = _candidateApprove(
          validator.usableRecords,
          investor.key,
          partnership,
          proposal.id,
        );
        final summary = settlementConsent(
          validator.usableRecords,
          partnershipKeys: keys,
          proposal: proposal,
          answer: candidate,
        );
        expect(summary, isNotNull);

        // The real approve is saved. Now core reports the settled period.
        final real = await investor.next(
          partnership: partnership,
          type: 'approve',
          refersTo: proposal.id,
        );
        expect(
          await validator.receiveText(canonicalJson(real.toJson())),
          ReceiveOutcome.accepted,
        );
        final closed = periodShares(
          validator.usableRecords,
          partnershipKeys: keys,
        ).where((p) => !p.open).toList();
        final settled = closed.single;

        expect(summary!.periodIndex, settled.index);
        expect(summary.result, settled.result);
        expect(summary.shares.investor, settled.shares.investor);
        expect(summary.shares.manager, settled.shares.manager);
        expect(summary.ratio, settled.ratio);
        expect(
          summary.result,
          summary.shares.investor + summary.shares.manager,
        );
      },
    );

    test('a reject as the answer gives no summary, so no Approve', () async {
      final (validator, investor, manager, partnership) =
          await setUpPartnership();
      final proposal = await manager.next(
        partnership: partnership,
        type: 'settlement',
        body: {
          'cut': {investor.key: 1, manager.key: 0},
        },
      );
      await validator.receiveText(canonicalJson(proposal.toJson()));

      final reject = Record(
        v: 1,
        id: testId('candidate-reject'),
        partnership: partnership,
        author: investor.key,
        seq: 2,
        prevHash: recordHash(
          validator.usableRecords
              .firstWhere((r) => r.author == investor.key)
              .toJson(),
        ),
        type: 'reject',
        body: const {},
        refersTo: proposal.id,
        note: '',
        time: '2026-10-06T10:00:00Z',
        sig: '',
      );

      final summary = settlementConsent(
        validator.usableRecords,
        partnershipKeys: {investor.key, manager.key},
        proposal: proposal,
        answer: reject,
      );
      expect(summary, isNull);
    });

    test(
      'a withdrawal summary equals the totals core reports once it is effective',
      () async {
        final (validator, investor, manager, partnership) =
            await setUpPartnership();
        final keys = {investor.key, manager.key};

        // The manager asks for a profit withdrawal of 1000.
        final request = await manager.next(
          partnership: partnership,
          type: 'withdraw_request',
          body: {'amount': 1000, 'kind': 'profit'},
        );
        await validator.receiveText(canonicalJson(request.toJson()));

        // Before the answer: the summary uses an unsaved investor approve.
        final candidate = _candidateApprove(
          validator.usableRecords,
          investor.key,
          partnership,
          request.id,
        );
        final summary = withdrawalConsent(
          validator.usableRecords,
          partnershipKeys: keys,
          request: request,
          answer: candidate,
        );
        expect(summary, isNotNull);
        expect(summary!.amount, 1000);
        expect(summary.kind, 'profit');

        // The real approve is saved. The totals must match core's.
        final real = await investor.next(
          partnership: partnership,
          type: 'approve',
          refersTo: request.id,
        );
        await validator.receiveText(canonicalJson(real.toJson()));
        final total = totalProfitWithdrawn(
          validator.usableRecords,
          partnershipKeys: keys,
        );
        expect(summary.totalProfitWithdrawn, total[manager.key]);
      },
    );
  });

  group('reversal consent (spec section 5, 6.5, 6.7)', () {
    test('reversing an invest changes capital and cash, no period fields', () async {
      final (validator, investor, manager, partnership) =
          await setUpPartnership();
      final keys = {investor.key, manager.key};

      final invest = await investor.next(
        partnership: partnership,
        type: 'invest',
        body: {'amount': 100000},
      );
      await validator.receiveText(canonicalJson(invest.toJson()));

      // The manager reverses the investor's record, so the investor answers.
      final reversal = await manager.next(
        partnership: partnership,
        type: 'reversal',
        refersTo: invest.id,
      );
      await validator.receiveText(canonicalJson(reversal.toJson()));

      final candidate = _candidateApprove(
        validator.usableRecords,
        investor.key,
        partnership,
        reversal.id,
      );
      final consent = reversalConsent(
        validator.usableRecords,
        partnershipKeys: keys,
        reversal: reversal,
        answer: candidate,
      );

      expect(consent, isNotNull);
      expect(consent!.targetType, 'invest');
      expect(consent.targetAmount, 100000);
      expect(consent.capitalChange, -100000);
      expect(consent.cashChange, -100000);
      expect(consent.periodIndex, isNull);
      expect(consent.periodOpen, isNull);
      expect(consent.resultChange, isNull);
      expect(consent.shareCorrection, isNull);
      expect(consent.freedBudgetId, isNull);
    });

    test(
      'reversing a capital withdraw_request gives capital and cash back',
      () async {
        final (validator, investor, manager, partnership) =
            await setUpPartnership();
        final keys = {investor.key, manager.key};

        await validator.receiveText(
          canonicalJson(
            (await investor.next(
              partnership: partnership,
              type: 'invest',
              body: {'amount': 100000},
            )).toJson(),
          ),
        );
        final withdraw = await investor.next(
          partnership: partnership,
          type: 'withdraw_request',
          body: {'amount': 20000, 'kind': 'capital'},
        );
        await validator.receiveText(canonicalJson(withdraw.toJson()));
        // A withdraw_request needs the other partner's approval before it is
        // effective (spec section 5), so it must be approved before anything
        // can reverse it.
        await validator.receiveText(
          canonicalJson(
            (await manager.next(
              partnership: partnership,
              type: 'approve',
              refersTo: withdraw.id,
            )).toJson(),
          ),
        );

        final reversal = await manager.next(
          partnership: partnership,
          type: 'reversal',
          refersTo: withdraw.id,
        );
        await validator.receiveText(canonicalJson(reversal.toJson()));

        final candidate = _candidateApprove(
          validator.usableRecords,
          investor.key,
          partnership,
          reversal.id,
        );
        final consent = reversalConsent(
          validator.usableRecords,
          partnershipKeys: keys,
          reversal: reversal,
          answer: candidate,
        );

        expect(consent, isNotNull);
        expect(consent!.targetType, 'withdraw_request');
        expect(consent.capitalChange, 20000);
        expect(consent.cashChange, 20000);
        expect(consent.periodIndex, isNull);
      },
    );

    test(
      'reversing a sale in the still-open period changes its provisional result',
      () async {
        final (validator, investor, manager, partnership) =
            await setUpPartnership();
        final keys = {investor.key, manager.key};

        final sale = await manager.next(
          partnership: partnership,
          type: 'sale',
          body: {'amount': 50000},
        );
        await validator.receiveText(canonicalJson(sale.toJson()));

        // The investor reverses the manager's record, so the manager answers.
        final reversal = await investor.next(
          partnership: partnership,
          type: 'reversal',
          refersTo: sale.id,
        );
        await validator.receiveText(canonicalJson(reversal.toJson()));

        final candidate = _candidateApprove(
          validator.usableRecords,
          manager.key,
          partnership,
          reversal.id,
        );
        final consent = reversalConsent(
          validator.usableRecords,
          partnershipKeys: keys,
          reversal: reversal,
          answer: candidate,
        );

        expect(consent, isNotNull);
        expect(consent!.targetType, 'sale');
        expect(consent.cashChange, -50000);
        expect(consent.periodIndex, 1);
        expect(consent.periodOpen, isTrue);
        expect(consent.resultChange, -50000);
        expect(consent.shareCorrection, isNull);
        expect(consent.deficitCorrectionChange, isNull);
      },
    );

    test(
      'reversing an expense in the open period frees its budget and raises the result',
      () async {
        final (validator, investor, manager, partnership) =
            await setUpPartnership();
        final keys = {investor.key, manager.key};

        await validator.receiveText(
          canonicalJson(
            (await manager.next(
              partnership: partnership,
              type: 'sale',
              body: {'amount': 100000},
            )).toJson(),
          ),
        );

        final budget = await investor.next(
          partnership: partnership,
          type: 'budget_proposal',
          body: {'grantee': manager.key, 'amount': 30000},
        );
        await validator.receiveText(canonicalJson(budget.toJson()));
        await validator.receiveText(
          canonicalJson(
            (await manager.next(
              partnership: partnership,
              type: 'approve',
              refersTo: budget.id,
            )).toJson(),
          ),
        );

        final expense = await manager.next(
          partnership: partnership,
          type: 'expense',
          body: {'amount': 12000, 'receiptHash': null},
          refersTo: budget.id,
        );
        await validator.receiveText(canonicalJson(expense.toJson()));

        // The investor reverses the manager's expense, so the manager answers.
        final reversal = await investor.next(
          partnership: partnership,
          type: 'reversal',
          refersTo: expense.id,
        );
        await validator.receiveText(canonicalJson(reversal.toJson()));

        final candidate = _candidateApprove(
          validator.usableRecords,
          manager.key,
          partnership,
          reversal.id,
        );
        final consent = reversalConsent(
          validator.usableRecords,
          partnershipKeys: keys,
          reversal: reversal,
          answer: candidate,
        );

        expect(consent, isNotNull);
        expect(consent!.targetType, 'expense');
        expect(consent.cashChange, 12000);
        expect(consent.periodOpen, isTrue);
        expect(consent.resultChange, 12000);
        expect(consent.freedBudgetId, budget.id);
        expect(consent.freedBudgetAmount, 12000);
      },
    );

    test(
      'reversing a sale in a closed period books a prior-period correction',
      () async {
        final (validator, investor, manager, partnership) =
            await setUpPartnership();
        final keys = {investor.key, manager.key};

        final sale = await manager.next(
          partnership: partnership,
          type: 'sale',
          body: {'amount': 50000},
        );
        await validator.receiveText(canonicalJson(sale.toJson()));

        // Settle period 1, closing it.
        final settlement = await manager.next(
          partnership: partnership,
          type: 'settlement',
          body: {
            'cut': {investor.key: investor.seq, manager.key: manager.seq},
          },
        );
        await validator.receiveText(canonicalJson(settlement.toJson()));
        await validator.receiveText(
          canonicalJson(
            (await investor.next(
              partnership: partnership,
              type: 'approve',
              refersTo: settlement.id,
            )).toJson(),
          ),
        );

        // The closed period's shares before any correction: 60/40 of 50000.
        // A trailing open period (empty so far) always follows the last cut.
        final before = periodShares(
          validator.usableRecords,
          partnershipKeys: keys,
        ).firstWhere((p) => !p.open);
        expect(before.shares.manager, 20000);

        // The investor reverses the manager's (now settled) sale.
        final reversal = await investor.next(
          partnership: partnership,
          type: 'reversal',
          refersTo: sale.id,
        );
        await validator.receiveText(canonicalJson(reversal.toJson()));

        final candidate = _candidateApprove(
          validator.usableRecords,
          manager.key,
          partnership,
          reversal.id,
        );
        final consent = reversalConsent(
          validator.usableRecords,
          partnershipKeys: keys,
          reversal: reversal,
          answer: candidate,
        );

        expect(consent, isNotNull);
        expect(consent!.targetType, 'sale');
        expect(consent.cashChange, -50000);
        // The sale's own period (1) is closed: this is a correction, not a
        // direct change to that period's own (frozen) result.
        expect(consent.periodIndex, 1);
        expect(consent.periodOpen, isFalse);
        expect(consent.resultChange, isNull);
        // The whole 50000 result disappears, so the whole settled shares
        // reverse: manager loses 20000, investor loses 30000.
        expect(consent.shareCorrection!.manager, -20000);
        expect(consent.shareCorrection!.investor, -30000);
      },
    );

    test('a reversal of a non-reversible type gives no consent', () async {
      final (validator, investor, manager, partnership) =
          await setUpPartnership();
      final keys = {investor.key, manager.key};

      final proposal = await manager.next(
        partnership: partnership,
        type: 'ratio_proposal',
        body: {
          'ratio': {'investor': 50, 'manager': 50},
          'effectiveFrom': '2026-11-01',
        },
      );
      await validator.receiveText(canonicalJson(proposal.toJson()));
      // Approved, so the proposal is genuinely effective — the point of this
      // test is the type guard, not a target that was never effective at all.
      await validator.receiveText(
        canonicalJson(
          (await investor.next(
            partnership: partnership,
            type: 'approve',
            refersTo: proposal.id,
          )).toJson(),
        ),
      );

      // Reversing a ratio_proposal is invalid in v1 (spec section 5), so
      // approving it can never cancel anything.
      final reversal = await investor.next(
        partnership: partnership,
        type: 'reversal',
        refersTo: proposal.id,
      );
      await validator.receiveText(canonicalJson(reversal.toJson()));

      final candidate = _candidateApprove(
        validator.usableRecords,
        manager.key,
        partnership,
        reversal.id,
      );
      final consent = reversalConsent(
        validator.usableRecords,
        partnershipKeys: keys,
        reversal: reversal,
        answer: candidate,
      );
      expect(consent, isNull);
    });
  });

  group('budget consent (spec section 5, 6.4)', () {
    test('a budget inside the cash on hand is not over-committed', () async {
      final (validator, investor, manager, partnership) =
          await setUpPartnership();
      final keys = {investor.key, manager.key};

      await validator.receiveText(
        canonicalJson(
          (await investor.next(
            partnership: partnership,
            type: 'invest',
            body: {'amount': 100000},
          )).toJson(),
        ),
      );

      final proposal = await investor.next(
        partnership: partnership,
        type: 'budget_proposal',
        body: {'grantee': manager.key, 'amount': 40000},
      );
      await validator.receiveText(canonicalJson(proposal.toJson()));

      final consent = budgetConsent(
        validator.usableRecords,
        partnershipKeys: keys,
        proposal: proposal,
      );

      expect(consent, isNotNull);
      expect(consent!.grantee, manager.key);
      expect(consent.amount, 40000);
      expect(consent.cashBalance, 100000);
      expect(consent.openBudgets, 0);
      expect(consent.overCommitted, isFalse);
    });

    test(
      'a budget that would push open budgets past cash on hand is flagged',
      () async {
        final (validator, investor, manager, partnership) =
            await setUpPartnership();
        final keys = {investor.key, manager.key};

        await validator.receiveText(
          canonicalJson(
            (await investor.next(
              partnership: partnership,
              type: 'invest',
              body: {'amount': 50000},
            )).toJson(),
          ),
        );

        final earlier = await investor.next(
          partnership: partnership,
          type: 'budget_proposal',
          body: {'grantee': manager.key, 'amount': 30000},
        );
        await validator.receiveText(canonicalJson(earlier.toJson()));
        await validator.receiveText(
          canonicalJson(
            (await manager.next(
              partnership: partnership,
              type: 'approve',
              refersTo: earlier.id,
            )).toJson(),
          ),
        );

        final proposal = await investor.next(
          partnership: partnership,
          type: 'budget_proposal',
          body: {'grantee': manager.key, 'amount': 30000},
        );
        await validator.receiveText(canonicalJson(proposal.toJson()));

        final consent = budgetConsent(
          validator.usableRecords,
          partnershipKeys: keys,
          proposal: proposal,
        );

        expect(consent, isNotNull);
        expect(consent!.cashBalance, 50000);
        expect(consent.openBudgets, 30000);
        // 50000 cash < 30000 already open + 30000 proposed.
        expect(consent.overCommitted, isTrue);
      },
    );
  });

  group('ratio consent (spec 6.6)', () {
    test('shows the ratio from the create next to the proposed one', () async {
      final (validator, investor, manager, partnership) =
          await setUpPartnership();
      final keys = {investor.key, manager.key};
      // The create needs the manager's approval before any ratio is active
      // (spec section 5).
      await validator.receiveText(
        canonicalJson(
          (await manager.next(
            partnership: partnership,
            type: 'approve',
            refersTo: partnership,
          )).toJson(),
        ),
      );

      final proposal = await manager.next(
        partnership: partnership,
        type: 'ratio_proposal',
        body: {
          'ratio': {'investor': 50, 'manager': 50},
          'effectiveFrom': '2026-11-01',
        },
      );
      await validator.receiveText(canonicalJson(proposal.toJson()));

      final consent = ratioConsent(
        validator.usableRecords,
        partnershipKeys: keys,
        proposal: proposal,
      );

      expect(consent, isNotNull);
      expect(consent!.currentRatio, const Ratio(investor: 60, manager: 40));
      expect(consent.proposedRatio, const Ratio(investor: 50, manager: 50));
      expect(consent.effectiveFrom, '2026-11-01');
    });

    test('a malformed proposal gives no consent, not a crash', () async {
      final (validator, investor, manager, partnership) =
          await setUpPartnership();
      final keys = {investor.key, manager.key};

      // Built by hand: a ratio that does not sum to 100, bypassing the
      // validator on purpose (decision Q3b style).
      final proposal = await manager.next(
        partnership: partnership,
        type: 'ratio_proposal',
        body: {
          'ratio': {'investor': 70, 'manager': 50},
          'effectiveFrom': '2026-11-01',
        },
      );

      final consent = ratioConsent(
        [...validator.usableRecords, proposal],
        partnershipKeys: keys,
        proposal: proposal,
      );
      expect(consent, isNull);
    });
  });
}
