import 'approvals.dart';
import 'record.dart';

/// Record types a `reversal` may cancel in v1 (spec section 5). Reversing any
/// other type is invalid: it is flagged, shown in the UI, and has no effect.
const _reversibleTypes = {'invest', 'sale', 'expense', 'withdraw_request'};

/// The result of spec section 6.3 for one set of usable records.
class Effectiveness {
  /// Ids of records that count in calculations.
  final Set<String> effectiveIds;

  /// Ids of records cancelled by an effective `reversal`.
  final Set<String> cancelledIds;

  /// Reversal id -> the reason it is invalid, shown to both partners. A
  /// reversal is only flagged when its target exists and cannot be reversed.
  final Map<String, String> invalidReversals;

  const Effectiveness({
    required this.effectiveIds,
    required this.cancelledIds,
    required this.invalidReversals,
  });

  bool isEffective(Record record) => effectiveIds.contains(record.id);
}

/// Works out which usable records are effective, spec section 6.3.
///
/// Everything here is a pure function of the set [usable], so the same records
/// give the same answer on every device, in any arrival order. Approval
/// decisions are computed inside, so a caller cannot pass in a stale list.
///
/// [usable] must already be filtered by `Validator.usableRecords`.
Effectiveness computeEffective(
  Iterable<Record> usable, {
  required Set<String> partnershipKeys,
}) {
  final records = usable.toList();
  final byId = {for (final r in records) r.id: r};

  // A record that needs approval is blocked unless its decision is active.
  // Records that never need approval have no decision and are not blocked.
  final blockedIds = {
    for (final d in decideApprovals(records, partnershipKeys: partnershipKeys))
      if (d.status != DecisionStatus.active) d.target.id,
  };

  final invalidReversals = <String, String>{};
  final effectiveReversalIds = <String>{};
  final cancelledIds = <String>{};

  for (final record in records) {
    if (record.type != 'reversal') continue;

    final reason = _invalidReason(record, byId);
    if (reason != null) {
      invalidReversals[record.id] = reason;
      continue;
    }

    // A reversal whose target is not here yet has no effect yet. It is not
    // flagged, because the target may still arrive and make it valid.
    final target = byId[record.refersTo];
    if (target == null || blockedIds.contains(record.id)) continue;

    effectiveReversalIds.add(record.id);
    cancelledIds.add(target.id);
  }

  final effectiveIds = {
    for (final record in records)
      if (!blockedIds.contains(record.id) &&
          (record.type == 'reversal'
              ? effectiveReversalIds.contains(record.id)
              : !cancelledIds.contains(record.id)))
        record.id,
  };

  return Effectiveness(
    effectiveIds: effectiveIds,
    cancelledIds: cancelledIds,
    invalidReversals: invalidReversals,
  );
}

/// Returns why [reversal] is invalid, or `null` if it is not invalid.
String? _invalidReason(Record reversal, Map<String, Record> byId) {
  final targetId = reversal.refersTo;
  if (targetId == null) return 'reversal has no target';

  final target = byId[targetId];
  if (target == null) return null;

  // The list is short on purpose. Reversing `partnership_create` would destroy
  // the partnership, and a `reversal` of a `reversal` is not allowed in v1.
  if (!_reversibleTypes.contains(target.type)) {
    return 'cannot reverse a ${target.type} record';
  }
  return null;
}
