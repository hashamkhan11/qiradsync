import 'approvals.dart';
import 'effective.dart';
import 'record.dart';

/// One record's situation on screen (the "transactions" list and its detail
/// view). This is the single business rule behind that screen, so the UI
/// never has to re-derive "is this counted, and if not, why" on its own.
enum RecordStatus {
  /// Counted in every calculation right now (spec 6.3, 6.4, 6.7).
  effective,

  /// Needs the other partner's answer before it can take effect, and has
  /// none yet (spec section 5).
  pendingApproval,

  /// The other partner rejected it. Final; never takes effect.
  rejected,

  /// An effective `reversal` cancelled this record (spec section 5).
  cancelledByReversal,

  /// An `expense` that did not fit in its budget at its own position
  /// (spec 6.4). Final; a later reversal elsewhere never un-flags it.
  overBudget,

  /// An `approve`/`reject` that broke the settlement ordering rule
  /// (spec 6.7): kept on the ledger as evidence, never decides anything.
  invalidResponse,

  /// A second (or later) answer to the same target from a partner who had
  /// already answered it. Kept as evidence; only the first answer counts.
  ignoredResponse,

  /// This phone found a different previous record than the one this record
  /// chains from (spec 6.1 step 5). Never counted.
  chainInvalid,

  /// This author signed two different records at the same `seq`. This record
  /// and everything after it from that author are excluded (spec 6.1 step 4).
  equivocating,

  /// Not effective, for a reason none of the statuses above names — for
  /// example a bad amount, a malformed ratio, or a reversal of a type that
  /// can never be reversed.
  notCounted,
}

/// Classifies every record in [allRecords] into one [RecordStatus] each.
///
/// [usable] must be the same ledger's `Validator.usableRecords` — the
/// records [chainInvalidIds] and [equivocatingFromSeq] have already
/// excluded as chain-problem evidence (spec 6.1 steps 4–5). This function
/// only combines results [Validator], [decideApprovals] and
/// [computeEffective] already computed; it does not re-derive the chain or
/// approval rules, so it cannot drift from them.
///
/// Pure function of its inputs (hard rule: deterministic calculations), so
/// the list and detail screens can call it fresh on every build instead of
/// storing a status anywhere.
Map<String, RecordStatus> recordStatuses(
  Iterable<Record> allRecords, {
  required Iterable<Record> usable,
  required Set<String> chainInvalidIds,
  required Map<String, int> equivocatingFromSeq,
  required Set<String> partnershipKeys,
}) {
  final decisions = decideApprovals(usable, partnershipKeys: partnershipKeys);
  final effectiveness = computeEffective(usable, partnershipKeys: partnershipKeys);

  final decisionByTargetId = {for (final d in decisions) d.target.id: d};
  final ignoredResponseIds = {
    for (final d in decisions)
      for (final response in d.ignoredResponses) response.id,
  };

  RecordStatus statusOf(Record record) {
    if (chainInvalidIds.contains(record.id)) return RecordStatus.chainInvalid;

    final equivocatingFrom = equivocatingFromSeq[record.author];
    if (equivocatingFrom != null && record.seq >= equivocatingFrom) {
      return RecordStatus.equivocating;
    }

    // A record's own decision (if it needs one) says more than "effective"
    // can: a `partnership_create` counts in `effectiveIds` even while still
    // pending (spec 6.6's ratio default), so this check comes first.
    final decision = decisionByTargetId[record.id];
    if (decision?.status == DecisionStatus.pending) {
      return RecordStatus.pendingApproval;
    }
    if (decision?.status == DecisionStatus.dead) {
      return RecordStatus.rejected;
    }

    // An `approve`/`reject` that is evidence-only (broke the settlement
    // ordering rule, or lost to an earlier valid answer) would otherwise
    // read as "effective": neither type is gated by a budget, a reversal
    // or its own decision, so `_isEffective`'s default branch says yes.
    // Evidence status must win over that default.
    if (effectiveness.invalidResponses.containsKey(record.id)) {
      return RecordStatus.invalidResponse;
    }
    if (ignoredResponseIds.contains(record.id)) {
      return RecordStatus.ignoredResponse;
    }

    if (effectiveness.isEffective(record)) return RecordStatus.effective;
    if (effectiveness.cancelledIds.contains(record.id)) {
      return RecordStatus.cancelledByReversal;
    }
    if (effectiveness.expenseStatus[record.id] == ExpenseStatus.overBudget) {
      return RecordStatus.overBudget;
    }
    return RecordStatus.notCounted;
  }

  return {for (final record in allRecords) record.id: statusOf(record)};
}
