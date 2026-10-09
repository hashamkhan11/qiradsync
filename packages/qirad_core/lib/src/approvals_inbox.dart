import 'approvals.dart';
import 'effective.dart';
import 'record.dart';
import 'settlement.dart';
import 'settlement_states.dart';

/// The kinds of pending item the inbox can show (spec sections 5 and 6.7).
enum InboxKind {
  settlement,
  withdrawal,
  budget,
  ratio,
  partnershipStart,
  reversal,
}

/// One record that waits for this partner's answer.
class InboxItem {
  final Record target;
  final InboxKind kind;

  /// False when this partner cannot approve yet, or ever. Reject is always
  /// allowed, so the screen keeps the reject button in every case.
  final bool canApprove;

  /// Why approve is not allowed, or `null` when it is allowed. Shown to the
  /// partner in plain words.
  final String? blockedReason;

  const InboxItem({
    required this.target,
    required this.kind,
    required this.canApprove,
    required this.blockedReason,
  });
}

/// The items waiting for [myKey]'s answer, in a fixed order (author, then seq).
///
/// Why this is a pure function of the records: the same usable records give the
/// same list on every phone. A record is listed only when it is still pending
/// and its author is the other partner. A partner never answers their own
/// record, so those are never listed.
///
/// [usable] must already be filtered by `Validator.usableRecords`.
List<InboxItem> approvalsInbox(
  Iterable<Record> usable, {
  required Set<String> partnershipKeys,
  required String myKey,
}) {
  // A phone that is not a partner has no inbox.
  if (!partnershipKeys.contains(myKey)) return const [];

  final records = usable.toList();
  final decisions = decideApprovals(records, partnershipKeys: partnershipKeys);
  final parties = partiesOf(records);
  final settlements = parties == null
      ? <SettlementStatus>[]
      : settlementStatuses(records, parties: parties, decisions: decisions);

  // A partner can reverse their own still-pending record at any time, with no
  // approval needed, but only when that record's type is reversible at all
  // (spec section 5; `_reversibleTypes` in effective.dart — invest, sale,
  // expense, withdraw_request). A reversal is not itself reversible in v1, so
  // a pending reversal is never cancelled this way; it leaves the inbox only
  // once the other partner approves or rejects it. For a type this does
  // apply to, once that self-reversal is effective, the original request is
  // gone from both sides, so the other partner must stop seeing it as
  // something to answer.
  final effectiveness = computeEffective(
    records,
    partnershipKeys: partnershipKeys,
  );

  final items = <InboxItem>[];
  for (final decision in decisions) {
    final target = decision.target;
    if (decision.status != DecisionStatus.pending) continue;
    if (target.author == myKey) continue;
    if (effectiveness.cancelledIds.contains(target.id)) continue;

    final kind = _kindOf(target);
    if (kind == InboxKind.settlement) {
      final blocked = _settlementBlock(
        target,
        records: records,
        myKey: myKey,
        settlements: settlements,
        parties: parties,
      );
      items.add(
        InboxItem(
          target: target,
          kind: kind,
          canApprove: blocked == null,
          blockedReason: blocked,
        ),
      );
    } else {
      items.add(
        InboxItem(
          target: target,
          kind: kind,
          canApprove: true,
          blockedReason: null,
        ),
      );
    }
  }

  items.sort((a, b) {
    final byAuthor = a.target.author.compareTo(b.target.author);
    return byAuthor != 0 ? byAuthor : a.target.seq.compareTo(b.target.seq);
  });
  return items;
}

InboxKind _kindOf(Record target) {
  switch (target.type) {
    case 'settlement':
      return InboxKind.settlement;
    case 'withdraw_request':
      return InboxKind.withdrawal;
    case 'budget_proposal':
      return InboxKind.budget;
    case 'ratio_proposal':
      return InboxKind.ratio;
    case 'partnership_create':
      return InboxKind.partnershipStart;
    default:
      return InboxKind.reversal;
  }
}

/// Why the investor cannot approve this settlement yet, or `null` when approve
/// is allowed. Only the investor answers a settlement, so [myKey] is the
/// investor here.
///
/// The four checks run in this order, so each partner sees the first problem:
/// 1. An earlier proposal is still waiting. The ordering rule (spec 6.7) makes
///    any approve of this one invalid until the earlier one is answered.
/// 2. The cut names an investor record the investor has not written. The
///    investor's own approve gets the next free seq, so a cut value at or above
///    that seq can never be approved. This is final, not a sync delay.
/// 3. The phone does not hold the whole cut yet. This may clear after sync.
/// 4. The cut fails one of rules 3-5 (closed, dominating, not empty). This
///    reuses [cutProblem] — the same function `settlementStatuses` calls once
///    the settlement is approved — so the inbox never disagrees with what
///    actually becomes effective. Approving a settlement that fails here would
///    always be answered with it going `invalid` and never doing anything, so
///    it is blocked here instead of only being discovered after the fact.
String? _settlementBlock(
  Record target, {
  required List<Record> records,
  required String myKey,
  required List<SettlementStatus> settlements,
  required Parties? parties,
}) {
  // A malformed settlement is not in the proposal list, so it has no cut and
  // no approve can count for it.
  final index = settlements.indexWhere((s) => s.record.id == target.id);
  if (index < 0) return 'Not a valid settlement. Reject it.';

  if (index > 0 &&
      settlements.take(index).any((s) => s.state == SettlementState.waiting)) {
    return 'Answer the earlier settlement first.';
  }

  final cut = settlements[index].cut;
  final nextSeq = _nextSeqFor(records, myKey);
  if (cut[myKey]! >= nextSeq) {
    return 'Covers investor records that do not exist. Reject it.';
  }

  if (!cutIsHeld(records, cut)) {
    return 'Waiting for records to sync.';
  }

  // `settlements` is only ever non-empty (so `index >= 0` above) when
  // `parties` is not null — both come from the same `partiesOf(records)`
  // call in `approvalsInbox`.
  final previous = _previousEffectiveCut(settlements, index, parties!);
  final problem = cutProblem(records, parties, cut, previous);
  if (problem != null) return _cutProblemMessage(problem);
  return null;
}

/// The cut of the last settlement before [index] that became effective, or
/// zero for both partners if none has yet — the same starting point
/// [cutProblem]'s domination and not-empty rules (cut rules 4 and 5) compare
/// against, and the same one `settlementStatuses` tracks as it walks the
/// proposals in order.
Map<String, int> _previousEffectiveCut(
  List<SettlementStatus> settlements,
  int index,
  Parties parties,
) {
  for (var i = index - 1; i >= 0; i--) {
    if (settlements[i].state == SettlementState.effective) {
      return settlements[i].cut;
    }
  }
  return {parties.investor: 0, parties.manager: 0};
}

/// Plain words for each of [cutProblem]'s reasons (spec 6.7, cut rules 3-5).
/// A settlement that fails any of these can never become effective, so
/// Reject is the only useful answer — the same framing as the other final
/// blocks above.
String _cutProblemMessage(String problem) {
  switch (problem) {
    case 'covers nothing new':
      return 'This settlement covers nothing new. Reject it.';
    case 'does not cover the previous cut':
      return 'This settlement moves the cut backward. Reject it.';
    case 'refers to a record outside the cut':
      return 'This settlement refers to a record outside its own cut. Reject it.';
    default:
      return 'Not a valid settlement. Reject it.';
  }
}

/// The seq of this partner's next record: one more than the highest seq held.
int _nextSeqFor(List<Record> records, String myKey) {
  var highest = 0;
  for (final record in records) {
    if (record.author == myKey && record.seq > highest) highest = record.seq;
  }
  return highest + 1;
}
