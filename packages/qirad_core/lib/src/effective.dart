import 'approvals.dart';
import 'amounts.dart';
import 'ratio.dart';
import 'record.dart';
import 'settlement.dart';

/// Record types a `reversal` may cancel in v1 (spec section 5). Reversing any
/// other type is invalid: it is flagged, shown in the UI, and has no effect.
const _reversibleTypes = {'invest', 'sale', 'expense', 'withdraw_request'};

/// What the budget check (spec section 6.4) decided for one expense.
enum ExpenseStatus {
  /// Fitted in the budget at its own position, so it is counted in `used`.
  valid,

  /// Did not fit at its own position. Never counted, and never changes later.
  overBudget,

  /// Refers to a budget that is not effective, or the author is not the grantee.
  noEffectiveBudget,

  /// The amount is missing, not an integer, or not positive.
  badAmount,
}

/// The result of spec sections 6.3 and 6.4 for one set of usable records.
class Effectiveness {
  /// Ids of records that count in calculations.
  final Set<String> effectiveIds;

  /// Ids of records cancelled by an effective `reversal`.
  final Set<String> cancelledIds;

  /// Reversal id -> the reason it is invalid, shown to both partners. A
  /// reversal is only flagged when its target exists and cannot be reversed.
  final Map<String, String> invalidReversals;

  /// Expense id -> its budget status, fixed at the expense's own position.
  final Map<String, ExpenseStatus> expenseStatus;

  /// Budget id -> running `used` total after all its events. Stored as a
  /// calculated value for display only; it is recomputed every time.
  final Map<String, int> budgetUsed;

  /// Response id -> why it does not count, for responses that break the
  /// settlement ordering rule (spec 6.7). Shown to both partners as evidence.
  final Map<String, String> invalidResponses;

  const Effectiveness({
    required this.effectiveIds,
    required this.cancelledIds,
    required this.invalidReversals,
    required this.expenseStatus,
    required this.budgetUsed,
    required this.invalidResponses,
  });

  bool isEffective(Record record) => effectiveIds.contains(record.id);
}

/// Works out which usable records are effective, spec sections 6.3 and 6.4.
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

  final decisions = decideApprovals(records, partnershipKeys: partnershipKeys);
  final decisionByTargetId = {for (final d in decisions) d.target.id: d};

  // A record that needs approval is blocked unless its decision is active.
  // Records that never need approval have no decision and are not blocked.
  final blockedIds = {
    for (final d in decisions)
      if (d.status != DecisionStatus.active) d.target.id,
  };

  final invalidResponses = <String, String>{
    for (final d in decisions)
      for (final response in d.invalidResponses)
        response.id:
            'answered a settlement before answering an earlier one (spec 6.7)',
  };

  final parties = partiesOf(records);

  // Reversals do not depend on budgets, so they are worked out first.
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

  final expenseStatus = <String, ExpenseStatus>{};
  final budgetUsed = <String, int>{};

  for (final budget in records.where((r) => r.type == 'budget_proposal')) {
    final budgetAmount = positiveAmount(budget);
    final grantee = budget.body['grantee'];
    if (blockedIds.contains(budget.id) ||
        budgetAmount == null ||
        grantee is! String) {
      continue;
    }

    // Each event is placed at a `seq` in the grantee's chain, so the order is
    // the same on every device (decision 2026-10-03, budget ordering).
    final events = <_BudgetEvent>[];
    for (final record in records) {
      if (record.type == 'expense' &&
          record.refersTo == budget.id &&
          record.author == grantee) {
        events.add(_BudgetEvent(position: record.seq, record: record));
      }
      if (record.type == 'reversal' &&
          effectiveReversalIds.contains(record.id)) {
        final target = byId[record.refersTo];
        if (target == null ||
            target.refersTo != budget.id ||
            target.author != grantee) {
          continue;
        }

        // The grantee's own reversal sits at its own seq. The other partner's
        // reversal sits at the seq of the grantee's approve that made it effective.
        final position = record.author == grantee
            ? record.seq
            : decisionByTargetId[record.id]!.firstResponse!.seq;
        events.add(_BudgetEvent(position: position, record: record));
      }
    }
    events.sort((a, b) {
      final byPosition = a.position.compareTo(b.position);
      return byPosition != 0 ? byPosition : a.record.id.compareTo(b.record.id);
    });

    var used = 0;
    final freed = <String>{};
    for (final event in events) {
      final record = event.record;
      if (record.type == 'expense') {
        final amount = positiveAmount(record);
        if (amount == null) {
          expenseStatus[record.id] = ExpenseStatus.badAmount;
        } else if (used + amount <= budgetAmount) {
          expenseStatus[record.id] = ExpenseStatus.valid;
          used += amount;
        } else {
          expenseStatus[record.id] = ExpenseStatus.overBudget;
        }
      } else {
        // Only a valid expense frees budget, and only once. A second reversal
        // of the same expense must not free the same amount again.
        final expense = byId[record.refersTo]!;
        if (expenseStatus[expense.id] == ExpenseStatus.valid &&
            freed.add(expense.id)) {
          used -= positiveAmount(expense)!;
        }
      }
    }
    budgetUsed[budget.id] = used;
  }

  // Any expense that did not get a status above is not under an effective budget.
  for (final record in records.where((r) => r.type == 'expense')) {
    expenseStatus.putIfAbsent(record.id, () => ExpenseStatus.noEffectiveBudget);
  }

  final effectiveIds = {
    for (final record in records)
      if (!blockedIds.contains(record.id) &&
          _isEffective(
            record,
            effectiveReversalIds,
            cancelledIds,
            expenseStatus,
            parties,
          ))
        record.id,
  };

  return Effectiveness(
    effectiveIds: effectiveIds,
    cancelledIds: cancelledIds,
    invalidReversals: invalidReversals,
    expenseStatus: expenseStatus,
    budgetUsed: budgetUsed,
    invalidResponses: invalidResponses,
  );
}

class _BudgetEvent {
  final int position;
  final Record record;

  const _BudgetEvent({required this.position, required this.record});
}

bool _isEffective(
  Record record,
  Set<String> effectiveReversalIds,
  Set<String> cancelledIds,
  Map<String, ExpenseStatus> expenseStatus,
  Parties? parties,
) {
  if (record.type == 'reversal') {
    return effectiveReversalIds.contains(record.id);
  }
  if (cancelledIds.contains(record.id)) return false;
  // A settlement is effective only when it is a well-formed manager proposal.
  // Its approval is checked by the caller through the blocked set (spec 6.7).
  if (record.type == settlementType) {
    return parties != null && settlementCut(record, parties) != null;
  }
  if (record.type == 'expense') {
    return expenseStatus[record.id] == ExpenseStatus.valid;
  }
  // Type-specific checks (spec 6.3): a record with a bad amount, or a withdraw
  // of an unknown kind, must never reach the money totals.
  if (record.type == 'invest' || record.type == 'sale') {
    return positiveAmount(record) != null;
  }
  if (record.type == 'budget_proposal') {
    return positiveAmount(record) != null && record.body['grantee'] is String;
  }
  if (record.type == 'withdraw_request') {
    final kind = record.body['kind'];
    return positiveAmount(record) != null &&
        (kind == 'capital' || kind == 'profit');
  }
  // A ratio that does not add up to 100, or a date that is not YYYY-MM-DD,
  // would give wrong profit shares, so it is never effective (spec 6.6).
  if (record.type == 'partnership_create') {
    return ratioOf(record) != null;
  }
  if (record.type == 'ratio_proposal') {
    return ratioOf(record) != null && isIsoDate(record.body['effectiveFrom']);
  }
  return true;
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
