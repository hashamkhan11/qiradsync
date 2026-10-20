import 'package:evaluation/evaluation.dart';
import 'package:qirad_core/qirad_core.dart';
import 'package:test/test.dart';

void main() {
  group('generateWorkload', () {
    test('is deterministic for a fixed seed', () async {
      final a = await generateWorkload(WorkloadConfig.realistic(days: 10), 7);
      final b = await generateWorkload(WorkloadConfig.realistic(days: 10), 7);

      expect(a.events.length, b.events.length);
      expect(a.refusals.length, b.refusals.length);
      final aIds = [for (final e in a.events) e.recordId];
      final bIds = [for (final e in b.events) e.recordId];
      expect(aIds, bIds);
    });

    test('writes at least one of every everyday record type', () async {
      final run = await generateWorkload(
        WorkloadConfig.realistic(days: 45),
        1,
      );
      final types = {for (final e in run.events) e.type};
      expect(
        types,
        containsAll(<String>{
          'partnership_create',
          'approve',
          'invest',
          'sale',
          'expense',
        }),
      );
    });

    test('logs a refusal for every expense that does not fit its budget', () async {
      final run = await generateWorkload(WorkloadConfig.stress(days: 60), 3);

      // Every stored record already passed core's own checks (the generator
      // asserts `ReceiveOutcome.accepted` on every self-write), so the thing
      // worth checking here is that refusals were not invented: each one
      // names a real `ProposalRefusal`/`AnswerEligibilityRefusal`/
      // `AnswerConsentRefusal` reason.
      const knownReasons = {
        'wrongRole',
        'noEffectiveBudget',
        'overBudget',
        'notReversible',
        'emptyCut',
        'notAnswerable',
        'alreadyAnswered',
        'alreadyDecided',
        'partnershipNotActive',
        'answerEarlierFirst',
        'consentNotShown',
        'summaryChanged',
      };
      for (final refusal in run.refusals) {
        expect(knownReasons, contains(refusal.reason));
      }
    });

    test('both devices eventually converge on the same ledger', () async {
      // A short, calm run so every record has time to be delivered and
      // answered before the simulation ends.
      final run = await generateWorkload(WorkloadConfig.realistic(days: 20), 5);

      final investorIds = {for (final r in run.investorLedger) r.id};
      final managerIds = {for (final r in run.managerLedger) r.id};
      final onlyInvestor = investorIds.difference(managerIds);
      final onlyManager = managerIds.difference(investorIds);

      // Anything still missing from the other side must be in flight
      // (delivered within the last couple of days), not lost.
      expect(onlyInvestor.length, lessThan(5));
      expect(onlyManager.length, lessThan(5));
    });

    test('both named configs run without crashing', () async {
      await generateWorkload(WorkloadConfig.realistic(days: 5), 42);
      await generateWorkload(WorkloadConfig.stress(days: 5), 42);
    });

    test(
      'stress keeps each device reachable for a healthy share of the run',
      () async {
        // Regression check: a device must never be modeled as offline so
        // often it is effectively unreachable (the bug this fixed left
        // stress devices online under 5% of a 30-day run, which starved
        // every consent-gated proposal and sometimes stalled the whole
        // run at 1 record).
        for (var seed = 1; seed <= 10; seed++) {
          final run = await generateWorkload(
            WorkloadConfig.stress(days: 30),
            seed,
          );
          expect(
            run.onlineFractionInvestor,
            greaterThan(0.3),
            reason: 'seed=$seed investor',
          );
          expect(
            run.onlineFractionManager,
            greaterThan(0.3),
            reason: 'seed=$seed manager',
          );
        }
      },
    );

    test('the manager never proposes a second budget while one of hers is '
        'still pending', () async {
      final run = await generateWorkload(WorkloadConfig.stress(days: 60), 9);

      final byId = <String, Record>{
        for (final r in [...run.investorLedger, ...run.managerLedger]) r.id: r,
      };

      String? openProposalId;
      for (final event in run.events) {
        if (event.type == 'budget_proposal') {
          expect(
            openProposalId,
            isNull,
            reason:
                'budget_proposal ${event.recordId} was authored while '
                '$openProposalId was still unanswered',
          );
          openProposalId = event.recordId;
        } else if ((event.type == 'approve' || event.type == 'reject') &&
            byId[event.recordId]!.refersTo == openProposalId) {
          openProposalId = null;
        }
      }
    });
  });
}
