import 'approvals.dart';
import 'consent_summary.dart';
import 'record.dart';
import 'validator.dart';

/// Why answering a proposal would be refused, once a candidate answer record
/// exists (spec 6.7). Call [answerEligibility] (see `answer_eligibility.dart`)
/// first; these checks assume it already returned `null`.
enum AnswerConsentRefusal {
  /// This answer would be invalid under the settlement ordering rule (spec
  /// 6.7): an earlier settlement proposal is still unanswered. Applies to
  /// both an approve and a reject.
  answerEarlierFirst,

  /// An approve that would take effect needs the summary the user saw.
  consentNotShown,

  /// The numbers changed since the user saw them, for example a sync made a
  /// settlement effective (spec 6.7).
  summaryChanged,
}

/// The result of [answerConsent]: the reason, and the current summary for
/// whichever proposal type was being answered (the others are `null`), so a
/// caller can show the new numbers without recomputing them.
class AnswerConsentResult {
  const AnswerConsentResult(
    this.reason, {
    this.latestSettlement,
    this.latestWithdrawal,
    this.latestReversal,
    this.latestBudget,
    this.latestRatio,
  });

  final AnswerConsentRefusal reason;
  final SettlementConsent? latestSettlement;
  final WithdrawalConsent? latestWithdrawal;
  final ReversalConsent? latestReversal;
  final BudgetConsent? latestBudget;
  final RatioConsent? latestRatio;
}

/// Whether answering [targetId] with the already-built [candidate] record
/// (the writer's own `approve`/`reject` of it) would be refused, or `null`
/// when it is allowed.
///
/// [candidate] must come from `buildRecord`: the ordering check needs a real
/// record to test insertion with, and the consent checks need its `id`. A
/// reject only runs the ordering check — there is no summary to check for a
/// reject, since it never takes effect.
AnswerConsentResult? answerConsent({
  required String targetId,
  required bool approve,
  required Record candidate,
  required Validator validator,
  SettlementConsent? shownSettlement,
  WithdrawalConsent? shownWithdrawal,
  ReversalConsent? shownReversal,
  BudgetConsent? shownBudget,
  RatioConsent? shownRatio,
}) {
  final keys = validator.partnershipKeys ?? const <String>{};
  final usable = validator.usableRecords;
  final decisions = decideApprovals(usable, partnershipKeys: keys);
  final current = decisions.firstWhere((d) => d.target.id == targetId);

  // Spec 6.7: the investor's answer to settlement S_k (approve or reject)
  // is valid only if every earlier settlement proposal was already answered.
  if (current.target.type == 'settlement') {
    final withCandidate = decideApprovals([
      ...usable,
      candidate,
    ], partnershipKeys: keys);
    final decided = withCandidate.firstWhere((d) => d.target.id == targetId);
    if (decided.invalidResponses.any((r) => r.id == candidate.id)) {
      return const AnswerConsentResult(AnswerConsentRefusal.answerEarlierFirst);
    }
  }

  if (!approve) return null;

  switch (current.target.type) {
    case 'settlement':
      final now = settlementConsent(
        usable,
        partnershipKeys: keys,
        proposal: current.target,
        answer: candidate,
      );
      final reason = _staleness(now, shownSettlement);
      return reason == null
          ? null
          : AnswerConsentResult(reason, latestSettlement: now);

    case 'withdraw_request':
      final now = withdrawalConsent(
        usable,
        partnershipKeys: keys,
        request: current.target,
        answer: candidate,
      );
      final reason = _staleness(now, shownWithdrawal);
      return reason == null
          ? null
          : AnswerConsentResult(reason, latestWithdrawal: now);

    case 'reversal':
      final now = reversalConsent(
        usable,
        partnershipKeys: keys,
        reversal: current.target,
        answer: candidate,
      );
      final reason = _staleness(now, shownReversal);
      return reason == null
          ? null
          : AnswerConsentResult(reason, latestReversal: now);

    case 'budget_proposal':
      final now = budgetConsent(
        usable,
        partnershipKeys: keys,
        proposal: current.target,
      );
      final reason = _staleness(now, shownBudget);
      return reason == null
          ? null
          : AnswerConsentResult(reason, latestBudget: now);

    case 'ratio_proposal':
      final now = ratioConsent(
        usable,
        partnershipKeys: keys,
        proposal: current.target,
      );
      final reason = _staleness(now, shownRatio);
      return reason == null
          ? null
          : AnswerConsentResult(reason, latestRatio: now);

    default:
      return null;
  }
}

/// `now` is the summary core reports right now; `shown` is the one the user
/// saw. `null` means "this approve would have no effect," which is only a
/// problem if the user was shown a summary that no longer applies.
AnswerConsentRefusal? _staleness<T>(T? now, T? shown) {
  if (now == null) {
    return shown == null ? null : AnswerConsentRefusal.summaryChanged;
  }
  if (shown == null) return AnswerConsentRefusal.consentNotShown;
  return now == shown ? null : AnswerConsentRefusal.summaryChanged;
}
