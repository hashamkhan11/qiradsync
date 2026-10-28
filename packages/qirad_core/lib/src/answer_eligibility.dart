import 'approvals.dart';
import 'validator.dart';

/// Why [me] may not even attempt to answer a proposal, before any candidate
/// answer record is built (spec sections 5, 6.7, 7.4).
enum AnswerEligibilityRefusal {
  /// No pending proposal with this id that needs an answer from [me].
  notAnswerable,

  /// [me] already answered this proposal validly (spec 7.4, rule 3).
  alreadyAnswered,

  /// The other partner already answered this proposal validly.
  alreadyDecided,

  /// The partnership is not active yet (spec section 5): until the create is
  /// approved, nothing but the create (and the manager's own answer to it)
  /// may be written.
  partnershipNotActive,
}

/// Whether [me] may even attempt to answer [targetId], or `null` when it is
/// allowed.
///
/// `RecordWriter.answer` and the evaluation workload generator both call
/// this first, before building the candidate answer record — these checks
/// need no candidate, so a refusal here never spends an id on one. Once this
/// returns `null`, build the candidate with `buildRecord` and pass it to
/// [answerConsent] (see `answer_consent.dart`) for the remaining checks.
AnswerEligibilityRefusal? answerEligibility({
  required String targetId,
  required String me,
  required Validator validator,
}) {
  final keys = validator.partnershipKeys ?? const <String>{};
  final decisions = decideApprovals(
    validator.usableRecords,
    partnershipKeys: keys,
  );

  final decision = decisions.where((d) => d.target.id == targetId);
  if (decision.isEmpty || decision.single.target.author == me) {
    return AnswerEligibilityRefusal.notAnswerable;
  }
  final current = decision.single;
  if (current.hasValidResponseFrom(me)) {
    return AnswerEligibilityRefusal.alreadyAnswered;
  }
  if (current.status != DecisionStatus.pending) {
    return AnswerEligibilityRefusal.alreadyDecided;
  }
  if (current.target.type != 'partnership_create' &&
      partnershipStatus(decisions) != DecisionStatus.active) {
    return AnswerEligibilityRefusal.partnershipNotActive;
  }
  return null;
}
